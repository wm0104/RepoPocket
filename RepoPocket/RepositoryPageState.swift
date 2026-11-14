import Foundation
import Combine

/// Owned by the repository page, never by a recyclable List row.
@MainActor class RepositoryPageLoadState<Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private var key: String?
    private var completed = false
    private var request: Task<Value, Error>?
    private var requestID: UUID?

    func identityChanged() {}

    func load(key: String, refresh: Bool = false,
              operation: @escaping @MainActor () async throws -> Value,
              isValid: @escaping @MainActor () -> Bool = { true },
              errorText: @escaping (Error) -> String = { $0.localizedDescription }) async {
        if self.key != key {
            request?.cancel(); request = nil; requestID = nil
            identityChanged()
            self.key = key; value = nil; error = ""; completed = false; loading = false
        }
        guard isValid() else { return }
        if completed && !refresh { return }
        let pending: Task<Value, Error>, token: UUID
        if let running = request, let currentID = requestID {
            pending = running; token = currentID
        } else {
            // An unstructured request survives cancellation of one off-screen row.
            // Identity changes cancel it; token checks reject late completions.
            pending = Task {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
            token = UUID(); request = pending; requestID = token
            loading = true; error = ""
        }
        do {
            let result = try await pending.value
            guard requestID == token, self.key == key else { return }
            guard isValid() else {
                request = nil; requestID = nil; loading = false
                return
            }
            value = result; completed = true; error = ""
        } catch {
            guard requestID == token, self.key == key else { return }
            if isValid(), !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled {
                self.error = errorText(error); completed = true
            }
        }
        if requestID == token { request = nil; requestID = nil; loading = false }
    }
}

struct RepositoryReadmeContent {
    let branch: String
    let document: ReadmeDocument
}

@MainActor final class RepositoryReadmeState: RepositoryPageLoadState<RepositoryReadmeContent> {
    @Published var bodyHeight: CGFloat = 180
    @Published var expanded = false
    override func identityChanged() { bodyHeight = 180; expanded = false }
}
