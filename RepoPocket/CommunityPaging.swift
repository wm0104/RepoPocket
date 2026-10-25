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
    private var removedIDs = Set<Item.ID>()

    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func remove(id: Item.ID) {
        guard items.contains(where: { $0.id == id }) else { return }
        cancel()
        removedIDs.insert(id)
        items.removeAll { $0.id == id }
        // Deletions shift offset-based pages; reread the boundary and deduplicate.
        page = min(page, items.count / CommunityRules.pageSize + 1)
        more = true; limited = false; error = ""
    }
    func load(reset: Bool = false, api: GitHub, fetch: @escaping (Int) async throws -> [Item]) {
        if reset {
            cancel(); items = []; page = 1; more = true; limited = false; loaded = false; error = ""
            removedIDs = []
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
                let ids = Set(self.items.map { $0.id }).union(self.removedIDs)
                var seen = ids
                self.items += batch.filter { seen.insert($0.id).inserted }
                self.loaded = true
                let nextPage = self.removedIDs.isEmpty ? requestedPage + 1 : min(requestedPage + 1, self.items.count / CommunityRules.pageSize + 1)
                self.limited = batch.count == CommunityRules.pageSize && nextPage > CommunityRules.pageLimit
                self.more = batch.count == CommunityRules.pageSize && !self.limited
                self.page = nextPage
            } catch {
                guard self.generation == request, api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
