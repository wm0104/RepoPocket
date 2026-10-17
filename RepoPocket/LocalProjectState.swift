import Foundation
import Combine

struct LocalGitSnapshot { let status: LocalGitStatus; let history: LocalGitHistory }
@MainActor final class LocalProjectState: ObservableObject {
    @Published private(set) var snapshot: LocalGitSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var fresh = false
    @Published private(set) var error = ""
    @Published var selected = Set<String>()
    private var attempted = false
    private var request: Task<Void, Never>?
    private var requestID: UUID?
    private var revision = 0
    private var requestRevision = 0

    func check(force: Bool = false, valid: @escaping () -> Bool,
               load: @escaping () async throws -> LocalGitSnapshot) async {
        guard valid() else { return }
        if let request {
            let wanted = revision
            await request.value
            if wanted > requestRevision { await check(force: true, valid: valid, load: load) }
            return
        }
        if attempted && !force { return }
        attempted = true; busy = true; fresh = false; error = ""
        let id = UUID(), version = revision; requestID = id; requestRevision = version
        let pending = Task {
            defer { if self.requestID == id { self.requestID = nil; self.request = nil; self.busy = false } }
            do {
                let value = try await load()
                try Task.checkCancellation()
                guard self.requestID == id, valid() else { return }
                self.snapshot = value; self.fresh = version == self.revision
                self.selected.formIntersection(Set(value.status.files.filter { $0.blocked.isEmpty }.map(\.path)))
            } catch {
                if self.requestID == id, valid(), !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
        request = pending; await pending.value
    }
    func cancel() {
        // Navigating to a read-only child must not invalidate a completed result.
        guard request != nil else { return }
        requestID = nil; request?.cancel(); request = nil; busy = false; fresh = false; attempted = false
    }
    func filesChanged() {
        revision += 1; fresh = false; attempted = false
    }
    func selectAll() {
        guard !busy, let snapshot else { return }
        selected = Set(snapshot.status.files.filter { $0.blocked.isEmpty }.map(\.path))
    }
    func toggleSelection(_ paths: Set<String>) {
        guard !busy, !paths.isEmpty else { return }
        if paths.isSubset(of: selected) { selected.subtract(paths) }
        else { selected.formUnion(paths) }
    }
}
