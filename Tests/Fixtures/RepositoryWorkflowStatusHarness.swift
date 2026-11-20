import Foundation
#if !canImport(Combine)
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
#endif

enum CommunityRules { static let pageSize = 30; static let pageLimit = 10 }
enum RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
@MainActor enum AccountStore { static var generation = UUID() }
@MainActor final class GitHub {
    private let generation = AccountStore.generation
    var isCurrentSession: Bool { generation == AccountStore.generation }
}
struct Run: Identifiable { let id: Int; let status: String }
enum Failure: Error { case offline }

// PRODUCTION_STORE
// PRODUCTION_PRESENTATION

@MainActor private final class RowProbe {
    enum Phase { case active, background }
    var scenePhase = Phase.active
    let api = MockAPI(), repo = "owner/name"
    var latest: Run?
    var samples: [(Int?, UInt64)] = []
    @MainActor final class MockAPI {
        var isCurrentSession = true, requests = 0
        var replies: [Result<Run?, Error>] = []
        var beforeReturn: (() -> Void)?
        func latestRepositoryWorkflowRun(_ repo: String) async throws -> Run? {
            precondition(repo == "owner/name" && !replies.isEmpty)
            requests += 1
            beforeReturn?()
            return try replies.removeFirst().get()
        }
    }
    func recordSleep(nanoseconds: UInt64) async throws {
        samples.append((latest?.id, nanoseconds))
        if api.replies.isEmpty { throw CancellationError() }
    }
    // PRODUCTION_POLL
    func verify() async {
        latest = Run(id: 1, status: "completed")
        scenePhase = .background
        await poll()
        precondition(api.requests == 0)
        scenePhase = .active
        api.replies = [.success(nil), .success(latest), .success(Run(id: 2, status: "queued")),
                       .success(Run(id: 2, status: "in_progress")), .success(Run(id: 2, status: "completed")),
                       .failure(Failure.offline), .success(Run(id: 3, status: "requested"))]
        await poll()
        precondition(samples.map { $0.0 } == [nil, 1, 2, 2, 2, nil, 3])
        precondition(samples.map { $0.1 } == [30, 30, 10, 10, 30, 30, 10].map { UInt64($0) * 1_000_000_000 })
        api.replies = [.success(Run(id: 99, status: "completed"))]
        api.beforeReturn = { withUnsafeCurrentTask { $0?.cancel() } }
        await Task { await self.poll() }.value
        precondition(latest?.id == 3 && samples.count == 7, "A cancelled view cannot publish stale results")
        api.replies = [.success(nil)]
        api.beforeReturn = { self.api.isCurrentSession = false }
        await poll()
        precondition(latest?.id == 3 && samples.count == 7, "An old account cannot publish or poll again")
        api.beforeReturn = nil
    }
}

@main struct RepositoryWorkflowStatusHarness {
    @MainActor static func main() async throws {
        await RowProbe().verify()
        let api = GitHub(), store = CommunityPageStore<Run>()
        store.load(reset: true, api: api) { page in
            precondition(page == 1)
            return [Run(id: 12, status: "in_progress"), Run(id: 99, status: "completed")]
        }
        await store.waitForLoad()
        precondition(store.items.first?.id == 12, "Preserve API ordering; do not sort IDs or prefer a successful run")

        var gate: CheckedContinuation<[Run], Error>?
        store.load(reset: true, api: api) { _ in try await withCheckedThrowingContinuation { gate = $0 } }
        while gate == nil { await Task.yield() }
        store.cancel()
        gate?.resume(returning: [Run(id: 1, status: "stale")]); gate = nil
        for _ in 0..<30 { await Task.yield() }
        precondition(store.items.isEmpty && store.error.isEmpty && !store.busy)

        store.load(reset: true, api: api) { _ in try await withCheckedThrowingContinuation { gate = $0 } }
        while gate == nil { await Task.yield() }
        AccountStore.generation = UUID()
        gate?.resume(returning: [Run(id: 2, status: "old-account")]); gate = nil
        await store.waitForLoad()
        precondition(store.items.isEmpty, "A same-account reactivation is still a different session")

        let current = GitHub()
        store.load(reset: true, api: current) { _ in [] }
        await store.waitForLoad()
        precondition(store.loaded && store.items.first == nil)
        store.load(reset: true, api: current) { _ in throw Failure.offline }
        await store.waitForLoad()
        precondition(!store.error.isEmpty && store.items.first == nil)
        store.load(reset: true, api: current) { _ in [Run(id: 3, status: "completed")] }
        await store.waitForLoad()
        precondition(store.items.first?.id == 3 && store.error.isEmpty)

        for (status, conclusion, title, tone) in [
            ("in_progress", nil, "运行中", "yellow"), ("queued", nil, "等待运行", "yellow"),
            ("completed", "success", "成功", "green"), ("completed", "failure", "失败", "red"),
            ("completed", nil, "状态未知", "gray"), ("mystery", nil, "状态未知", "gray")
        ] as [(String, String?, String, String)] {
            let value = WorkflowStatusPresentation(status: status, conclusion: conclusion)
            precondition(value.title == title && value.tone == tone)
        }
        print("PASS repository latest/order, cancellation, account generation, empty/error and shared status mapping")
    }
}
