import Foundation

/// File operations are bounded to an explicitly authorized parent. Never overwrite.
enum DownloadRules {
    /// Migrate old relative labels without opening a file provider during launch.
    static func initialLabel(_ cached: String?, hasBookmark: Bool) -> String {
        guard hasBookmark else { return "请选择保存位置" }
        if let cached, cached.hasPrefix("/") { return cached }
        return "已保留下载位置；下次下载时更新完整路径，也可重新选择。"
    }
    /// Selecting our existing download folder must not create RepoPocket/RepoPocket.
    static func destinationFolder(in parent: URL) -> URL {
        parent.lastPathComponent == "RepoPocket" ? parent : parent.appendingPathComponent("RepoPocket", isDirectory: true)
    }
    static func safeName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        let clean = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" && $0 != "\\" }.map(String.init).joined()
        return clean.isEmpty || clean == "." || clean == ".." ? "file" : String(clean.prefix(180))
    }
    static func rejectSymlinks(_ url: URL) throws {
        // Do not standardize here: Foundation can rewrite /private/var to the
        // /var symlink even after the caller resolved it. Inspect each literal
        // filesystem component, without URL resource-value caching/following.
        var current = url.path
        while current != "/" && !current.isEmpty {
            if (try? FileManager.default.attributesOfItem(atPath: current)[.type] as? FileAttributeType) == .typeSymbolicLink {
                // Darwin's OS-owned /var alias is unavoidable in sandbox URLs.
                // Permit only this exact alias and destination, never user links.
                let systemAlias = current == "/var" && (try? FileManager.default.destinationOfSymbolicLink(atPath: current)) == "private/var"
                let absoluteSystemAlias = current == "/var" && (try? FileManager.default.destinationOfSymbolicLink(atPath: current)) == "/private/var"
                guard systemAlias || absoluteSystemAlias else { throw NSError(domain: "DownloadStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "目录含符号链接，请重新选择保存位置。", "rejectedPath": current]) }
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }
    static func save(_ source: URL, parent: URL, valid: () -> Bool,
                     fingerprint: (URL) throws -> String,
                     copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws -> URL {
        let fm = FileManager.default
        guard valid() else { throw CancellationError() }
        try rejectSymlinks(parent)
        let folder = destinationFolder(in: parent)
        try rejectSymlinks(folder)
        if fm.fileExists(atPath: folder.path) {
            guard (try fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeDirectory else { throw NSError(domain: "DownloadStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "保存位置不是文件夹，请重新选择。"]) }
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let name = safeName(source.lastPathComponent)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var target = folder.appendingPathComponent(name)
        var suffix = 1
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(stem + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext)); suffix += 1
        }
        let staging = folder.appendingPathComponent(".repopocket-" + UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: staging) }
        let expected = try fingerprint(source)
        try copy(source, staging)
        guard valid() else { throw CancellationError() }
        guard try fingerprint(staging) == expected else { throw NSError(domain: "DownloadStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "保存校验失败，请重试。"]) }
        guard valid() else { throw CancellationError() }
        // moveItem is exclusive (throws on an existing destination), not a replace.
        try fm.moveItem(at: staging, to: target)
        return target
    }
}

enum CacheRules {
    /// Total bytes of one cache directory; missing or unreadable entries count as zero.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
    /// Only the two dedicated cache children; never Documents, temp, downloads or Keychain.
    static func clear(root: URL, busy: Bool, remove: (URL) throws -> Void) throws {
        guard !busy else { throw NSError(domain: "Cache", code: 1, userInfo: [NSLocalizedDescriptionKey: "操作进行中，请稍后清理缓存。"]) }
        try DownloadRules.rejectSymlinks(root)
        let children = ["RepoPocketCache", "RepoPocketAvatars"].map { root.appendingPathComponent($0, isDirectory: true) }
        for child in children { try DownloadRules.rejectSymlinks(child) }
        for child in children {
            if FileManager.default.fileExists(atPath: child.path) { try remove(child) }
        }
    }
}
