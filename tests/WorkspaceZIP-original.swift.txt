import Foundation
import ZIPFoundation

// All archive paths are validated before writing any entry; extraction is staged
// under a unique private temporary directory, never on top of an existing checkout.
enum WorkspaceZIP {
    static func extract(_ source: URL, to directory: URL) throws {
        let archive = try Archive(url: source, accessMode: .read)
        var total: UInt64 = 0
        var paths = Set<String>()
        var entries = 0
        for entry in archive {
            entries += 1
            let path = entry.path
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let clean = entry.type == .directory && components.last == "" ? Array(components.dropLast()) : components
            guard !clean.isEmpty, clean.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\"), !path.contains("\0"), !path.contains(":"),
                  entry.type == .file || entry.type == .directory,
                  paths.insert(clean.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw AppError(text: "ZIP 含不安全、重复路径或符号链接：" + path)
            }
            guard entry.uncompressedSize <= 512 * 1024 * 1024,
                  total <= 1024 * 1024 * 1024 - entry.uncompressedSize, entries <= 20000 else {
                throw AppError(text: "ZIP 超限：最多 20,000 项、单文件 512 MiB、解压总计 1 GiB")
            }
            total += entry.uncompressedSize
        }
        guard entries > 0 else { throw AppError(text: "ZIP 为空") }
        let fm = FileManager.default
        for entry in archive {
            let target = directory.appendingPathComponent(entry.path).standardizedFileURL
            guard Array(target.pathComponents.prefix(directory.standardizedFileURL.pathComponents.count)) == directory.standardizedFileURL.pathComponents else {
                throw AppError(text: "ZIP 路径越界")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let checksum = try archive.extract(entry, to: target, skipCRC32: false)
            guard checksum == entry.checksum else { throw AppError(text: "ZIP CRC 校验失败：" + entry.path) }
        }
    }
}
