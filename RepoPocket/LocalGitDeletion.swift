import Foundation

struct LocalGitDeletionTarget {
    let path: String
    let directory: Bool
    let files: Int
    let bytes: Int64
    fileprivate let signature: String
}

/// A confirmation owns a snapshot, never just a path that could now name other data.
enum LocalGitDeletion {
    static func prepare(root: URL, path: String, check: () throws -> Void = {}) throws -> LocalGitDeletionTarget {
        let url = try LocalGitFileAccess.path(root: root, relative: path)
        return try LocalGitFileAccess.coordinate(url, writing: false) { coordinated in
            guard coordinated.standardizedFileURL == url.standardizedFileURL else { throw changed() }
            return try snapshot(root: root, path: path, check: check)
        }
    }

    static func delete(root: URL, target: LocalGitDeletionTarget, check: () throws -> Void = {}) throws {
        let url = try LocalGitFileAccess.path(root: root, relative: target.path)
        try LocalGitFileAccess.coordinate(url, writing: true, deleting: true) { coordinated in
            guard coordinated.standardizedFileURL == url.standardizedFileURL,
                  try snapshot(root: root, path: target.path, check: check).signature == target.signature else { throw changed() }
            try check()
            try FileManager.default.removeItem(at: coordinated)
        }
    }

    private static func snapshot(root: URL, path: String, check: () throws -> Void) throws -> LocalGitDeletionTarget {
        var records = [[String: String]](), files = 0, bytes: Int64 = 0
        func visit(_ relative: String, depth: Int) throws {
            try check()
            guard records.count < 2000, depth <= 64 else { throw LocalGitError(text: "文件夹过大或层级过深，请在系统“文件”中处理。") }
            let url = try LocalGitFileAccess.path(root: root, relative: relative)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw LocalGitError(text: "不能确认符号链接或特殊文件的删除，请在系统“文件”中处理。")
            }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern
            var record = ["path": relative, "type": type!.rawValue, "device": device.stringValue,
                          "inode": inode.stringValue, "modified": String(modified ?? 0)]
            if type == .typeRegular {
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                files += 1; bytes += size
                guard files <= 1000, bytes <= 512 * 1024 * 1024 else {
                    throw LocalGitError(text: "确认删除限 1000 个文件、合计 512 MiB，请在系统“文件”中处理。")
                }
                record["hash"] = try LocalGitFileAccess.fileFingerprint(root: root, path: relative)
                let after = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (after[.systemFileNumber] as? NSNumber) == inode,
                      (after[.modificationDate] as? Date) == (attributes[.modificationDate] as? Date),
                      (after[.size] as? NSNumber)?.int64Value == size else { throw changed() }
            }
            records.append(record)
            if type == .typeDirectory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                guard children.count <= 2000 else { throw LocalGitError(text: "文件夹项目过多，请在系统“文件”中处理。") }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            }
        }
        try visit(path, depth: 0)
        try check()
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        return LocalGitDeletionTarget(path: path, directory: records.first?["type"] == FileAttributeType.typeDirectory.rawValue,
                                      files: files, bytes: bytes, signature: LocalGitFileAccess.fingerprint(data))
    }

    private static func changed() -> LocalGitError {
        LocalGitError(text: "内容或目录身份在确认后发生变化，已停止删除。请刷新后重新确认。")
    }
}
