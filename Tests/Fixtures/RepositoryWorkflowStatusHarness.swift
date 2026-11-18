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

@main struct RepositoryWorkflowStatusHarness {
    @MainActor static func main() async throws {
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
