import Foundation
import Combine

/// A page is committed only when both the request and account still match.
/// Keeping the next page unchanged on failure makes Retry lossless.
@MainActor final class CommunityPageStore<Item: Identifiable>: ObservableObject where Item.ID: Hashable {
    @Published private(set) var items: [Item] = []
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var more = true
    @Published private(set) var limited = false
    @Published private(set) var error = ""
    private var page = 1
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func load(reset: Bool = false, api: GitHub, fetch: @escaping (Int) async throws -> [Item]) {
        if reset {
            cancel(); items = []; page = 1; more = true; limited = false; loaded = false; error = ""
        }
        guard !busy, more, api.isCurrentSession else { return }
        let request = generation, requestedPage = page
        busy = true; error = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.busy = false; self.task = nil } }
            do {
                let batch = try await fetch(requestedPage)
                try Task.checkCancellation()
                guard self.generation == request, api.isCurrentSession else { return }
                let ids = Set(self.items.map { $0.id })
                var seen = ids
                self.items += batch.filter { seen.insert($0.id).inserted }
                self.loaded = true
                self.limited = batch.count == CommunityRules.pageSize && requestedPage >= CommunityRules.pageLimit
                self.more = batch.count == CommunityRules.pageSize && !self.limited
                self.page += 1
            } catch {
                guard self.generation == request, api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
