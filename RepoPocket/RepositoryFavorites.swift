import Foundation
import CryptoKit
import Combine

/// User-owned bookmarks are durable data, not an evictable response cache.
struct RepositoryFavorites {
    let accountID: String
    var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RepositoryFavorites", isDirectory: true)
    static let maximumBytes = 2_097_152
    static let maximumCount = 200
    private struct Record: Codable { let accountID: String; let repositories: [Repository] }
    var location: URL {
        root.appendingPathComponent(SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func read() throws -> [Repository] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= Self.maximumBytes else { throw AppError(text: "收藏文件过大，未覆盖原数据。") }
        let data = try Data(contentsOf: location)
        guard data.count <= Self.maximumBytes else { throw AppError(text: "收藏文件过大。") }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.accountID == accountID else { throw AppError(text: "收藏数据不属于当前账号。") }
        try validate(record.repositories)
        return record.repositories
    }
    func save(_ repositories: [Repository]) throws {
        try validate(repositories)
        let bytes = try JSONEncoder().encode(Record(accountID: accountID, repositories: repositories))
        guard bytes.count <= Self.maximumBytes else { throw AppError(text: "收藏信息过大，未覆盖原数据。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: location, options: .atomic)
    }
    private func validate(_ repositories: [Repository]) throws {
        guard !accountID.isEmpty, repositories.count <= Self.maximumCount else { throw AppError(text: "最多收藏200个仓库。") }
        var ids = Set<Int>(), names = Set<String>()
        for repository in repositories {
            let name = try RepositoryInput.parse(repository.full_name)
            guard repository.id > 0, name == repository.full_name,
                  ids.insert(repository.id).inserted, names.insert(name.lowercased()).inserted else {
                throw AppError(text: "收藏数据重复或无效，未覆盖原数据。")
            }
        }
    }
    static func removeAccount(_ accountID: String) { try? FileManager.default.removeItem(at: Self(accountID: accountID).location) }
}

@MainActor final class RepositoryFavoritesState: ObservableObject {
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var error = ""
    private let storage: RepositoryFavorites
    private let isCurrent: () -> Bool
    init(accountID: String, isCurrent: @escaping () -> Bool) {
        storage = RepositoryFavorites(accountID: accountID); self.isCurrent = isCurrent
        do { repositories = try storage.read() } catch { self.error = error.localizedDescription }
    }
    func contains(_ repository: Repository) -> Bool { repositories.contains { $0.id == repository.id } }
    func add(_ repository: Repository) throws {
        try update { old in
            if let index = old.firstIndex(where: { $0.id == repository.id }) { old[index] = repository }
            else { old.append(repository) }
        }
    }
    func remove(_ ids: Set<Int>) throws { try update { $0.removeAll { ids.contains($0.id) } } }
    func reorder(_ ids: [Int]) throws {
        try update { old in
            guard ids.count == old.count, Set(ids) == Set(old.map(\.id)) else { throw AppError(text: "收藏已变化，请重新排序。") }
            let values = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            old = try ids.map { id in guard let value = values[id] else { throw AppError(text: "收藏已变化。") }; return value }
        }
    }
    private func update(_ change: (inout [Repository]) throws -> Void) throws {
        do {
            guard isCurrent() else { throw CancellationError() }
            var values = try storage.read()
            try change(&values)
            try storage.save(values)
            repositories = values; error = ""
        } catch { self.error = error.localizedDescription; throw error }
    }
}
