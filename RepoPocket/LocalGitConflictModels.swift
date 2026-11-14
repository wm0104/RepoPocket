import Foundation

struct LocalGitConflictSession: Decodable {
    let active: Bool
    let session: String?
    let head: String?
    let reference: String?
    let sourceRef: String?
    let sourceSHA: String?
    let method: String?
    let phase: String?
    let recoveryRef: String?
    let indexFingerprint: String?
    let resolved: Int?
    let files: [File]?
    struct File: Decodable, Identifiable {
        let path: String
        let resolved: Bool
        let oursExists: Bool
        let theirsExists: Bool
        var id: String { path }
    }
    var arguments: [String: Any] {
        ["session": session ?? "", "expectedHead": head ?? "", "expectedRef": reference ?? "", "indexFingerprint": indexFingerprint ?? ""]
    }
    var targetName: String { (reference ?? "").replacingOccurrences(of: "refs/heads/", with: "") }
    var sourceName: String { (sourceRef ?? "").replacingOccurrences(of: "refs/heads/", with: "") }
}
struct LocalGitConflictFile: Decodable {
    struct Side: Decodable {
        let exists: Bool
        let binary: Bool
        let text: String
        let oid: String
    }
    let path: String
    let ours: Side
    let theirs: Side
    let binary: Bool
    let resolved: Bool
    let result: String
    let resultOID: String
    let resultExists: Bool
    let indexFingerprint: String
}

/// Work in UTF-16 ranges, just like NSString and UITextView. Never reconstruct unaffected lines.
enum LocalGitConflictBlocks {
    struct Block: Identifiable {
        let range: NSRange
        let ours: String
        let theirs: String
        var id: Int { range.location }
    }
    static func parse(_ text: String) -> [Block] {
        let value = text as NSString
        var result: [Block] = []
        var start: Int?, separator: NSRange?, oursStart = 0
        var offset = 0
        while offset < value.length {
            let range = value.lineRange(for: NSRange(location: offset, length: 0))
            let line = value.substring(with: range)
            if line.hasPrefix("<<<<<<< ") {
                guard start == nil else { return [] }
                start = range.location; oursStart = NSMaxRange(range); separator = nil
            } else if line.trimmingCharacters(in: .newlines) == "=======", start != nil {
                guard separator == nil else { return [] }; separator = range
            } else if line.hasPrefix(">>>>>>> "), let begin = start, let middle = separator {
                result.append(Block(range: NSRange(location: begin, length: NSMaxRange(range) - begin),
                                    ours: value.substring(with: NSRange(location: oursStart, length: middle.location - oursStart)),
                                    theirs: value.substring(with: NSRange(location: NSMaxRange(middle), length: range.location - NSMaxRange(middle)))))
                start = nil; separator = nil
            }
            offset = NSMaxRange(range)
        }
        return start == nil ? result : []
    }
    static func applying(_ block: Block, choice: String, to text: String) -> String {
        let replacement = choice == "ours" ? block.ours : (choice == "theirs" ? block.theirs : block.ours + block.theirs)
        return (text as NSString).replacingCharacters(in: block.range, with: replacement)
    }
}
