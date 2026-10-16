import Foundation

struct LocalGitError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
struct LocalGitProject: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let bookmark: Data
    let identity: String
    let metadataID: UUID
    let usesPrivateGit: Bool
    var active = true
}
struct LocalGitChange: Codable, Identifiable, Equatable {
    let path: String
    let kind: String
    let fingerprint: String
    let blocked: String
    var id: String { path }
    var label: String { kind == "added" ? "新增" : (kind == "deleted" ? "删除" : "修改") }
}
struct LocalGitStatus: Codable {
    let head: String
    let branch: String
    let reference: String
    let files: [LocalGitChange]
    let staged: [String]
    let repoState: Int
    var canCommit: Bool { staged.isEmpty && repoState == 0 }
}
struct LocalGitDiff: Codable { let text: String; let binary: Bool; let truncated: Bool }
struct LocalGitCommit: Codable, Identifiable {
    let sha: String
    let message: String
    let author: String
    let time: Double
    var id: String { sha }
}
struct LocalGitHistory: Codable {
    let commits: [LocalGitCommit]
    let ahead: Int
    let behind: Int
    let tracking: Bool
    let remote: String
}
struct LocalGitDocument { let text: String; let fingerprint: String }
struct LocalGitReply: Codable { let commit: String?; let head: String? }
enum LocalGitDate {
    static func string(_ time: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy年M月d日 ah:mm"
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
}

enum LocalGitRules {
    static func remote(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if value.hasPrefix("https://github.com/") {
            guard let parts = URLComponents(string: value), parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.query == nil, parts.fragment == nil else { throw LocalGitError(text: "请输入 GitHub HTTPS 仓库地址。") }
            name = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { name = value }
        let clean = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        let fields = clean.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard fields.count == 2, fields.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw LocalGitError(text: "请输入 owner/repository 或完整 GitHub HTTPS 仓库地址。")
        }
        return "https://github.com/" + clean + ".git"
    }
    static func child(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", value.lowercased() != ".git",
              !value.contains("/"), !value.contains("\\"), !value.contains("\0") else { throw LocalGitError(text: "请输入不含路径分隔符的新文件夹名称。") }
        return value
    }
}
