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

    func check(force: Bool = false, valid: @escaping () -> Bool,
               load: @escaping () async throws -> LocalGitSnapshot) async {
        guard valid() else { return }
        if let request { await request.value; return }
        if attempted && !force { return }
        attempted = true; busy = true; fresh = false; error = ""
        let id = UUID(); requestID = id
        let pending = Task {
            do {
                let value = try await load()
                try Task.checkCancellation()
                guard self.requestID == id, valid() else { return }
                self.snapshot = value; self.fresh = true
                self.selected.formIntersection(Set(value.status.files.map(\.path)))
            } catch {
                if self.requestID == id, valid(), !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if self.requestID == id { self.requestID = nil; self.request = nil; self.busy = false }
        }
        request = pending; await pending.value
    }
    func cancel() {
        requestID = nil; request?.cancel(); request = nil; busy = false; fresh = false
    }
}
