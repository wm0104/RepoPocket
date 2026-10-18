import Foundation
import CryptoKit

enum LocalGitFileAccess {
    static let textLimit = 1024 * 1024
    static func identity(_ root: URL) throws -> String {
        let values = try FileManager.default.attributesOfItem(atPath: root.path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              let device = values[.systemNumber] as? NSNumber, let file = values[.systemFileNumber] as? NSNumber else {
            throw LocalGitError(text: "无法核对原目录身份，请重新选择文件夹。")
        }
        return device.stringValue + ":" + file.stringValue
    }
    static func path(root: URL, relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !relative.contains("\\"), !relative.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw LocalGitError(text: "不能访问项目外路径或 Git 元数据。")
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            let info = try FileManager.default.attributesOfItem(atPath: url.path)
            guard info[.type] as? FileAttributeType != .typeSymbolicLink else { throw LocalGitError(text: "不跟随符号链接读写文件。") }
        }
        return url
    }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fileFingerprint(root: URL, path: String) throws -> String {
        let url = try self.path(root: root, relative: path)
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular, let size = info[.size] as? NSNumber,
              size.int64Value <= 128 * 1024 * 1024 else { throw LocalGitError(text: "仅支持项目内 128 MiB 内的普通文件。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func read(root: URL, path: String) throws -> LocalGitDocument {
        let url = try self.path(root: root, relative: path)
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber, size.intValue <= textLimit else { throw LocalGitError(text: "编辑器只打开 1 MiB 内的普通文本文件。") }
        let bytes = try Data(contentsOf: url, options: [])
        guard bytes.count <= textLimit, !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw LocalGitError(text: "不是可编辑的 UTF-8 文本，不会截断或转换保存。") }
        return LocalGitDocument(text: text, fingerprint: fingerprint(bytes))
    }
    static func write(root: URL, path: String, text: String, expected: String) throws {
        let bytes = Data(text.utf8)
        guard bytes.count <= textLimit else { throw LocalGitError(text: "超过 1 MiB，未保存，也不会截断内容。") }
        let url = try self.path(root: root, relative: path)
        try coordinate(url, writing: true) { coordinated in
            guard try read(root: root, path: path).fingerprint == expected, coordinated.standardizedFileURL == url.standardizedFileURL else { throw LocalGitError(text: "文件被外部修改，未覆盖；请先保留编辑内容并重新比较。") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try bytes.write(to: coordinated, options: .atomic)
            if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: coordinated.path) }
        }
    }
    static func replaceBinary(root: URL, path: String, source: URL, expected: String) throws {
        let target = try self.path(root: root, relative: path)
        let info = try FileManager.default.attributesOfItem(atPath: source.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber, size.int64Value <= 128 * 1024 * 1024 else {
            throw LocalGitError(text: "仅保存 128 MiB 内的普通文件。")
        }
        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
        guard bytes.count <= 128 * 1024 * 1024 else { throw LocalGitError(text: "文件过大，未保存。") }
        try coordinate(target, writing: true) { coordinated in
            guard coordinated.standardizedFileURL == target.standardizedFileURL,
                  try fileFingerprint(root: root, path: path) == expected else {
                throw LocalGitError(text: "本地文件已被其他工具修改，未覆盖，请重新打开。")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            try bytes.write(to: coordinated, options: .atomic)
            if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: coordinated.path) }
        }
    }
    static func delete(root: URL, path: String, expected: String) throws {
        let url = try self.path(root: root, relative: path)
        try coordinate(url, writing: true) { coordinated in
            guard try fileFingerprint(root: root, path: path) == expected, coordinated.standardizedFileURL == url.standardizedFileURL else { throw LocalGitError(text: "文件在确认后变化，已停止删除。") }
            try FileManager.default.removeItem(at: coordinated)
        }
    }
    /// Removes a whole folder inside the project; the root itself is never removable.
    static func deleteDirectory(root: URL, path: String) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalGitError(text: "不能删除项目根目录。") }
        let url = try self.path(root: root, relative: path)
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeDirectory else { throw LocalGitError(text: "目标不是文件夹。") }
        try coordinate(url, writing: true) { coordinated in
            guard coordinated.standardizedFileURL == url.standardizedFileURL else { throw LocalGitError(text: "文件夹在确认后变化，已停止删除。") }
            try FileManager.default.removeItem(at: coordinated)
        }
    }
    static func coordinate<T>(_ url: URL, writing: Bool, operation: (URL) throws -> T) throws -> T {
        var failure: NSError?, result: Result<T, Error>?
        let work: (URL) -> Void = { coordinated in result = Result { try operation(coordinated) } }
        let coordinator = NSFileCoordinator()
        if writing { coordinator.coordinate(writingItemAt: url, options: [], error: &failure, byAccessor: work) }
        else { coordinator.coordinate(readingItemAt: url, options: [], error: &failure, byAccessor: work) }
        if let failure { throw failure }
        guard let result else { throw LocalGitError(text: "文件提供器没有完成操作，请重新授权原目录。") }
        return try result.get()
    }
    static func withRoot<T>(_ project: LocalGitProject, internalRoot: URL, operation: (URL) throws -> T) throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: project.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let owned = internalRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !stale, scoped || resolved.path == owned.path || resolved.path.hasPrefix(owned.path + "/"),
              try identity(url) == project.identity else { throw LocalGitError(text: "原目录授权失效或身份变化，请重新选择同一个原文件夹；不会创建替代目录。") }
        return try operation(url)
    }
}
