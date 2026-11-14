import Foundation
import ZIPFoundation

// Validate the entire archive before writing, into an empty private staging directory.
enum WorkspaceZIP {
    private static func components(_ url: URL) -> [String] {
        // Foundation may retain a directory URL's final slash as a path component.
        // Keep the filesystem root but discard that non-name trailing component.
        var result = url.pathComponents
        if result.count > 1 && result.last == "/" { result.removeLast() }
        return result
    }
    static func extract(_ source: URL, to directory: URL) throws {
        let fm = FileManager.default
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try fm.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw AppError(text: "ZIP 必须解压到空的非符号链接临时目录")
        }
        // Canonicalize once; never compare an unresolved base to a resolved child.
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let baseComponents = components(base)
        let archive = try Archive(url: source, accessMode: .read)
        var total: UInt64 = 0
        var paths: [String: Bool] = [:]
        var spellings: [String: String] = [:]
        var entries = 0
        for entry in archive {
            entries += 1
            let path = entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let clean = entry.type == .directory && parts.last == "" ? Array(parts.dropLast()) : parts
            guard !clean.isEmpty, clean.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\"), !path.contains("\0"), !path.contains(":"),
                  entry.type == .file || entry.type == .directory else {
                throw AppError(text: "ZIP 含不安全路径或符号链接：" + path)
            }
            let name = clean.joined(separator: "/")
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard paths[key] == nil else { throw AppError(text: "ZIP 含重复或大小写/Unicode 冲突路径：" + path) }
            paths[key] = entry.type == .directory
            // Include implicit parent directories in collision checks (A/x vs a/y).
            for count in 1...clean.count {
                let prefix = clean.prefix(count).joined(separator: "/")
                let folded = prefix.precomposedStringWithCanonicalMapping.lowercased()
                if let previous = spellings[folded], !previous.utf8.elementsEqual(prefix.utf8) {
                    throw AppError(text: "ZIP 含大小写/Unicode 冲突目录：" + path)
                }
                spellings[folded] = prefix
            }
            guard entry.uncompressedSize <= 512 * 1024 * 1024,
                  total <= 1024 * 1024 * 1024 - entry.uncompressedSize, entries <= 20000 else {
                throw AppError(text: "ZIP 超限：最多 20,000 项、单文件 512 MiB、解压总计 1 GiB")
            }
            total += entry.uncompressedSize
            let target = base.appendingPathComponent(name, isDirectory: entry.type == .directory)
            let targetComponents = components(target.resolvingSymlinksInPath().standardizedFileURL)
            guard targetComponents.count > baseComponents.count,
                  Array(targetComponents.prefix(baseComponents.count)) == baseComponents else {
                throw AppError(text: "ZIP 路径越界：" + path)
            }
        }
        guard entries > 0 else { throw AppError(text: "ZIP 为空") }
        for key in paths.keys {
            let parts = key.split(separator: "/")
            if parts.count > 1 {
                for count in 1..<parts.count where paths[parts.prefix(count).joined(separator: "/")] == false {
                    throw AppError(text: "ZIP 文件与目录冲突：" + key)
                }
            }
        }
        for entry in archive {
            let name = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let target = base.appendingPathComponent(name, isDirectory: entry.type == .directory)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let checksum = try archive.extract(entry, to: target, skipCRC32: false)
            guard checksum == entry.checksum else { throw AppError(text: "ZIP CRC 校验失败：" + entry.path) }
        }
    }
}
