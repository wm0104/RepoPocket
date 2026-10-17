import Foundation

/// Holds the picker grants until the queued copy has actually finished.
final class LocalGitImportSources {
    let urls: [URL]
    private let scoped: [URL]
    init(_ urls: [URL]) {
        self.urls = urls
        scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { for url in scoped { url.stopAccessingSecurityScopedResource() } }
}

struct LocalGitImportResult {
    let paths: [String]
    let bytes: Int64
}

/// Imports bytes into the original worktree. Never edits the index or pushes.
enum LocalGitImport {
    private struct Entry {
        let relative: String
        let directory: Bool
        let size: Int64
    }
    static func copy(sources: [URL], into root: URL, directory: String = "",
                     check: () throws -> Void = {}) throws -> LocalGitImportResult {
        guard !sources.isEmpty, sources.count <= 1000 else { throw LocalGitError(text: "请选择 1 至 1000 个文件或文件夹。") }
        let base = directory.isEmpty ? root : try LocalGitFileAccess.path(root: root, relative: directory)
        let identity = try LocalGitFileAccess.identity(base)
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
        var entries: [Entry] = [], names = Set<String>(), bytes: Int64 = 0, files = 0
        for source in sources {
            try check()
            let name = try LocalGitRules.child(source.lastPathComponent)
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  !FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) else {
                throw LocalGitError(text: "目标已有同名项目：\(name)。请先重命名；不会覆盖或合并原文件。")
            }
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != rootPath, !path.hasPrefix(rootPath + "/"),
                  basePath != path, !basePath.hasPrefix(path + "/") else {
                throw LocalGitError(text: "所选内容已在当前项目中，或包含目标项目；不会重复导入。")
            }
            try LocalGitFileAccess.coordinate(source, writing: false) { coordinated in
                try scan(coordinated, relative: name, entries: &entries, bytes: &bytes, files: &files, check: check)
            }
        }
        let stage = base.appendingPathComponent(".repopocket-import-" + UUID().uuidString, isDirectory: true)
        try LocalGitFileAccess.coordinate(base, writing: true) { destination in
            guard try LocalGitFileAccess.identity(destination) == identity else { throw LocalGitError(text: "目标文件夹已变化，请重新选择。") }
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        }
        let stageIdentity = try LocalGitFileAccess.identity(stage)
        // This UUID directory is created by this operation, never supplied by a user.
        defer { removeStage(stage, identity: stageIdentity) }
        for source in sources {
            try check()
            let name = source.lastPathComponent
            try coordinateCopy(source, into: stage) { coordinated, destination in
                for entry in entries where entry.relative == name || entry.relative.hasPrefix(name + "/") {
                    try check()
                    guard try LocalGitFileAccess.identity(base) == identity,
                          try LocalGitFileAccess.identity(destination) == stageIdentity else { throw LocalGitError(text: "导入目录已变化，已停止。") }
                    let suffix = String(entry.relative.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let input = suffix.isEmpty ? coordinated : try LocalGitFileAccess.path(root: coordinated, relative: suffix)
                    let output = destination.appendingPathComponent(entry.relative, isDirectory: entry.directory)
                    if entry.directory { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false) }
                    else { try copyFile(input, to: output, expectedSize: entry.size, check: check) }
                }
            }
        }
        var published = [String]()
        do {
            for source in sources {
                try check()
                let name = source.lastPathComponent
                try publish(stage.appendingPathComponent(name), to: base.appendingPathComponent(name),
                            parentIdentity: identity, stageIdentity: stageIdentity, check: check)
                published.append(name)
            }
        } catch {
            // Preserve published items if another app changes the destination.
            // Never recursively roll back a folder that now belongs to the user.
            if !published.isEmpty { throw LocalGitError(text: "已保留导入的 \(published.count) 个项目；其余未完成：" + error.localizedDescription) }
            throw error
        }
        let prefix = directory.isEmpty ? "" : directory + "/"
        return LocalGitImportResult(paths: entries.filter { !$0.directory }.map { prefix + $0.relative }, bytes: bytes)
    }
    private static func coordinateCopy(_ source: URL, into stage: URL, operation: (URL, URL) throws -> Void) throws {
        var failure: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: stage, options: [], error: &failure) { input, output in
            result = Result { try operation(input, output) }
        }
        if let failure { throw failure }
        guard let result else { throw LocalGitError(text: "文件提供器未完成导入。") }
        try result.get()
    }
    private static func publish(_ source: URL, to target: URL, parentIdentity: String, stageIdentity: String,
                                check: () throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var failure: NSError?, result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: [], error: &failure) { input, output in
            result = Result {
                try check()
                guard try LocalGitFileAccess.identity(input.deletingLastPathComponent()) == stageIdentity,
                      try LocalGitFileAccess.identity(output.deletingLastPathComponent()) == parentIdentity else { throw LocalGitError(text: "导入目录已变化，已停止。") }
                guard !FileManager.default.fileExists(atPath: output.path) else { throw LocalGitError(text: "导入时出现同名项目：\(target.lastPathComponent)，未覆盖。") }
                coordinator.item(at: input, willMoveTo: output)
                try FileManager.default.moveItem(at: input, to: output)
                coordinator.item(at: input, didMoveTo: output)
            }
        }
        if let failure { throw failure }
        guard let result else { throw LocalGitError(text: "文件提供器未完成保存。") }
        try result.get()
    }
    private static func removeStage(_ stage: URL, identity: String) {
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: stage, options: .forDeleting, error: &failure) { owned in
            if (try? LocalGitFileAccess.identity(owned)) == identity { try? FileManager.default.removeItem(at: owned) }
        }
    }
    private static func scan(_ source: URL, relative: String, entries: inout [Entry],
                             bytes: inout Int64, files: inout Int, check: () throws -> Void) throws {
        try check()
        guard entries.count < 2000, relative.split(separator: "/").count <= 64 else { throw LocalGitError(text: "导入项目过多或文件夹层级过深。") }
        _ = try LocalGitRules.child(source.lastPathComponent)
        let info = try FileManager.default.attributesOfItem(atPath: source.path)
        let type = info[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw LocalGitError(text: "不导入符号链接或特殊文件：" + source.lastPathComponent) }
        let size = type == .typeRegular ? (info[.size] as? NSNumber)?.int64Value ?? 0 : 0
        if type == .typeRegular {
            bytes += size; files += 1
            guard size <= 128 * 1024 * 1024, bytes <= 512 * 1024 * 1024, files <= 1000 else {
                throw LocalGitError(text: "导入限单文件 128 MiB、合计 512 MiB、1000 个文件；未修改原文件。")
            }
        }
        entries.append(Entry(relative: relative, directory: type == .typeDirectory, size: size))
        if type == .typeDirectory {
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            guard children.count <= 2000 else { throw LocalGitError(text: "单个文件夹项目过多。") }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try scan(child, relative: relative + "/" + child.lastPathComponent, entries: &entries, bytes: &bytes, files: &files, check: check)
            }
        }
    }
    private static func copyFile(_ input: URL, to output: URL, expectedSize: Int64, check: () throws -> Void) throws {
        let info = try FileManager.default.attributesOfItem(atPath: input.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              (info[.size] as? NSNumber)?.int64Value == expectedSize else { throw LocalGitError(text: "来源文件在检查后变化，请重新导入。") }
        try Data().write(to: output, options: .withoutOverwriting)
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var copied: Int64 = 0
        while true {
            try check()
            guard let data = try reader.read(upToCount: 256 * 1024), !data.isEmpty else { break }
            copied += Int64(data.count)
            guard copied <= expectedSize else { throw LocalGitError(text: "来源文件在复制时增大，已停止。") }
            try writer.write(contentsOf: data)
        }
        guard copied == expectedSize else { throw LocalGitError(text: "来源文件在复制时变化，已停止。") }
        if let mode = info[.posixPermissions] as? NSNumber {
            try FileManager.default.setAttributes([.posixPermissions: mode.intValue & 0o777], ofItemAtPath: output.path)
        }
    }
}
