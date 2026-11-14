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
    @Published private(set) var updatedAt: Date?
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
    func seed(_ items: [Item], updatedAt: Date) {
        guard !loaded, !busy else { return }
        self.items = items; self.updatedAt = updatedAt; loaded = true
    }
    func waitForLoad() async { await task?.value }
    func refreshItems(ids: [Item.ID], api: GitHub, fetch: @escaping (Item.ID) async throws -> Item) {
        guard !busy, !ids.isEmpty, api.isCurrentSession else { return }
        let request = generation
        busy = true; error = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.busy = false; self.task = nil } }
            do {
                var updates: [Item.ID: Item] = [:]
                for id in ids {
                    let value = try await fetch(id)
                    try Task.checkCancellation()
                    guard self.generation == request, api.isCurrentSession else { return }
                    guard value.id == id else { throw CocoaError(.coderReadCorrupt) }
                    updates[id] = value
                }
                self.items = self.items.map { updates[$0.id] ?? $0 }
                self.updatedAt = Date()
            } catch {
                guard self.generation == request, api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func load(reset: Bool = false, preserveItems: Bool = false, api: GitHub, fetch: @escaping (Int) async throws -> [Item]) {
        let retainedPages = max(page - 1, (items.count + CommunityRules.pageSize - 1) / CommunityRules.pageSize)
        if reset {
            cancel()
            if !preserveItems { items = []; loaded = false; updatedAt = nil; page = 1; more = true; limited = false }
            error = ""
            removedIDs = []
        }
        guard !busy, reset || more, api.isCurrentSession else { return }
        let request = generation, requestedPage = reset ? 1 : page
        let lastPage = reset && preserveItems ? max(1, min(CommunityRules.pageLimit, retainedPages)) : requestedPage
        busy = true; error = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.busy = false; self.task = nil } }
            do {
                var batch: [Item] = [], completedPage = requestedPage, lastCount = 0
                for currentPage in requestedPage...lastPage {
                    let values = try await fetch(currentPage)
                    try Task.checkCancellation()
                    guard self.generation == request, api.isCurrentSession else { return }
                    batch += values; completedPage = currentPage; lastCount = values.count
                    if values.count < CommunityRules.pageSize { break }
                }
                let ids = requestedPage == 1 ? self.removedIDs : Set(self.items.map { $0.id }).union(self.removedIDs)
                var seen = ids
                if requestedPage == 1 { self.items = batch.filter { seen.insert($0.id).inserted } }
                else { self.items += batch.filter { seen.insert($0.id).inserted } }
                self.updatedAt = Date()
                self.loaded = true
                let nextPage = self.removedIDs.isEmpty ? completedPage + 1 : min(completedPage + 1, self.items.count / CommunityRules.pageSize + 1)
                self.limited = lastCount == CommunityRules.pageSize && nextPage > CommunityRules.pageLimit
                self.more = lastCount == CommunityRules.pageSize && !self.limited
                self.page = nextPage
            } catch {
                guard self.generation == request, api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
