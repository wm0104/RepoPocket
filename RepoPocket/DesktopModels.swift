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


enum CommitDatePresentation {
    static func local(_ value: String, timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) -> String {
        let parser = ISO8601DateFormatter()
        var date = parser.date(from: value)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: value)
        }
        guard let date else { return "时间未知" }
        // Fixed China time in 12-hour form, matching the phone's clock style.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else { return "时间未知" }
        let suffix = hour < 12 ? "上午" : "下午"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%04d-%02d-%02d %@ %d:%02d", year, month, day, suffix, hour12, minute)
    }
}

struct ForkComparison: Decodable {
    let status: String
    let ahead_by: Int
    let behind_by: Int
    let total_commits: Int
    let commits: [DesktopCommit]
}
