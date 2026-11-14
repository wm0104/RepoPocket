import Foundation
import CryptoKit

/// Durable device-only order. Only authoritative membership reads may prune it.
struct StarListLocalOrder {
    let accountID: String
    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StarListLocalOrder", isDirectory: true)
    var root = Self.defaultRoot
    static let maximumBytes = 2_097_152
    private struct Record: Codable { let accountID: String; var lists: [String: [String]] }
    var location: URL {
        root.appendingPathComponent(SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    private func read() throws -> Record {
        guard !accountID.isEmpty else { throw AppError(text: "账号无效，未保存排序。") }
        guard FileManager.default.fileExists(atPath: location.path) else { return Record(accountID: accountID, lists: [:]) }
        guard try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= Self.maximumBytes else {
            throw AppError(text: "分类排序文件过大，未覆盖原数据。")
        }
        let data = try Data(contentsOf: location)
        guard data.count <= Self.maximumBytes else { throw AppError(text: "分类排序文件过大。") }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.accountID == accountID else { throw AppError(text: "排序不属于当前账号。") }
        for (listID, ids) in record.lists { try validate(ids, listID: listID) }
        return record
    }
    private func validate(_ ids: [String], listID: String) throws {
        guard !listID.isEmpty, ids.count <= 5000, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw AppError(text: "分类排序无效，未覆盖原数据。")
        }
    }
    static func reconciled(_ order: [String], members: [String]) -> [String] {
        let live = Set(members), known = Set(order)
        return order.filter { live.contains($0) } + members.filter { !known.contains($0) }
    }
    func orderedIDs(listID: String, members: [String]) throws -> [String] {
        try validate(members, listID: listID)
        return Self.reconciled(try read().lists[listID] ?? [], members: members)
    }
    func save(_ ids: [String], listID: String, isCurrent: () -> Bool) throws {
        guard isCurrent() else { throw CancellationError() }
        try validate(ids, listID: listID)
        var record = try read()
        guard record.lists[listID] != ids else { return }
        record.lists[listID] = ids
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= Self.maximumBytes else { throw AppError(text: "分类排序文件过大，未保存。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard isCurrent() else { throw CancellationError() }
        try bytes.write(to: location, options: .atomic)
    }
    static func removeAccount(_ accountID: String, root: URL = Self.defaultRoot) {
        try? FileManager.default.removeItem(at: Self(accountID: accountID, root: root).location)
    }
}
