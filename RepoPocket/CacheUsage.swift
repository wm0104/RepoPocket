import Foundation

/// Disk measurement is independent of SwiftUI's main-actor-isolated state.
enum CacheUsage {
    static func bytes() -> Int64 {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folders = ["RepoPocketCache", "RepoPocketAvatars"].map { root.appendingPathComponent($0, isDirectory: true) }
        let total = folders.reduce(Int64(0)) { $0 + CacheRules.directorySize($1) }
            + Int64(URLCache.shared.currentDiskUsage)
        return max(0, total)
    }
}
