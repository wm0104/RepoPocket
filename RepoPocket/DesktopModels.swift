import Foundation

struct DesktopBranch: Decodable, Identifiable {
    let name: String
    var id: String { name }
}
struct DesktopCommit: Decodable, Identifiable {
    let sha: String
    let commit: Info
    let files: [File]?
    let stats: Stats?
    var id: String { sha }
    struct Info: Decodable {
        let message: String
        let author: Author?
        let committer: Author?
    }
    struct Author: Decodable { let name: String?; let date: String? }
    struct Stats: Decodable { let additions: Int; let deletions: Int; let total: Int }
    struct File: Decodable, Identifiable {
        let filename: String
        let previous_filename: String?
        let status: String
        let additions: Int
        let deletions: Int
        let patch: String?
        var id: String { filename }
        var preview: String {
            guard let patch = patch, !patch.isEmpty else {
                return "无文本 diff：二进制文件或 GitHub 未提供 patch。"
            }
            return String(patch.prefix(100000)) + (patch.count > 100000 ? "\n…预览已截断（100,000 字符）" : "")
        }
    }
}
enum DesktopRules {
    static func validBranch(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", name != "HEAD", !name.hasPrefix("-"),
              !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains(".."), !name.contains("@{"), !name.contains("//"),
              !name.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }),
              !name.contains(where: { "~^:?*[\\".contains($0) }) else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
}
