import Foundation

struct CommitPatchRow: Identifiable {
    enum Kind { case context, addition, deletion, hunk, note, malformed }
    let id: Int
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String
    var marker: String { kind == .addition ? "+" : (kind == .deletion ? "−" : " ") }
}
struct CommitPatchResult {
    var rows: [CommitPatchRow] = []
    var limited = false
    var malformed = false
}
enum CommitPatchParser {
    static let byteLimit = 1024 * 1024
    static let rowLimit = 10_000
    static let lineLimit = 8_192
    static func visible(_ text: String, whitespace: Bool) -> String {
        whitespace ? text.replacingOccurrences(of: "\t", with: "⇥   ").replacingOccurrences(of: " ", with: "·") : text
    }
    static func parse(_ patch: String) throws -> CommitPatchResult {
        var result = CommitPatchResult()
        // UTF8 prefix is decoded safely at scalar boundaries; no full split of enormous input.
        let bounded = String(decoding: patch.utf8.prefix(byteLimit), as: UTF8.self)
        result.limited = patch.utf8.count > byteLimit
        let regex = try NSRegularExpression(pattern: "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@(.*)$")
        var old: Int?; var new: Int?
        var remainingOld = 0; var remainingNew = 0
        func add(_ kind: CommitPatchRow.Kind, _ text: String, _ o: Int? = nil, _ n: Int? = nil) {
            let short = String(text.prefix(lineLimit))
            if short.count < text.count { result.limited = true }
            result.rows.append(CommitPatchRow(id: result.rows.count, kind: kind, old: o, new: n, text: short))
        }
        for raw in bounded.split(separator: "\n", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            if result.rows.count >= rowLimit { result.limited = true; break }
            let line = String(raw)
            if line.hasPrefix("@@") {
                if remainingOld != 0 || remainingNew != 0 { result.malformed = true }
                let ns = line as NSString
                if let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let o = Int(ns.substring(with: m.range(at: 1))), let n = Int(ns.substring(with: m.range(at: 3))),
                   o < Int.max - rowLimit, n < Int.max - rowLimit {
                    old = o; new = n
                    remainingOld = m.range(at: 2).location == NSNotFound ? 1 : (Int(ns.substring(with: m.range(at: 2))) ?? 0)
                    remainingNew = m.range(at: 4).location == NSNotFound ? 1 : (Int(ns.substring(with: m.range(at: 4))) ?? 0)
                    add(.hunk, "区块：旧行 \(o)（\(remainingOld)行） → 新行 \(n)（\(remainingNew)行）" + ns.substring(with: m.range(at: 5)))
                } else { old = nil; new = nil; remainingOld = 0; remainingNew = 0; result.malformed = true; add(.malformed, "区块位置无法解析：" + line) }
            } else if line == "\\ No newline at end of file" {
                add(.note, "文件末尾没有换行")
            } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("diff --git ") || line.hasPrefix("index ") {
                add(.note, line)
            } else if let o = old, let n = new, let marker = line.first, ["+", "-", " "].contains(marker) {
                switch marker {
                case "+": add(.addition, String(line.dropFirst()), nil, n); new = n + 1; remainingNew -= 1
                case "-": add(.deletion, String(line.dropFirst()), o, nil); old = o + 1; remainingOld -= 1
                default: add(.context, String(line.dropFirst()), o, n); old = o + 1; new = n + 1; remainingOld -= 1; remainingNew -= 1
                }
                if remainingOld < 0 || remainingNew < 0 { result.malformed = true }
            } else if !line.isEmpty {
                result.malformed = true; add(.malformed, line)
            }
        }
        if remainingOld != 0 || remainingNew != 0 { result.malformed = true }
        return result
    }
}
