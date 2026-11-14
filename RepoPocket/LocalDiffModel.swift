import Foundation

/// Read-only preview. Lines retain their terminators; empty files have zero lines.
enum LocalDiffModel {
    enum Kind { case context, deletion, addition }
    struct Run { let text: String; let emphasized: Bool }
    struct Row: Identifiable {
        let id: Int
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let raw: String
        var runs: [Run]
    }
    enum Entry: Identifiable {
        case row(Int), gap(Range<Int>)
        var id: Int { switch self { case .row(let i): return i; case .gap(let r): return r.lowerBound } }
    }
    struct Result {
        let rows: [Row]
        let entries: [Entry]
        let changes: [Int]
        let additions: Int
        let deletions: Int
        let whitespaceOnly: Bool
        let degraded: Bool
    }
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // Split on the LF scalar, not Character (CRLF is one grapheme).
        let pieces = text.components(separatedBy: "\n")
        return pieces.enumerated().compactMap { i, part in
            if i < pieces.count - 1 { return part + "\n" }
            return part.isEmpty ? nil : part
        }
    }
    static func visible(_ text: String, whitespace: Bool) -> String {
        guard whitespace else { return text.replacingOccurrences(of: "\n", with: "") }
        return text.replacingOccurrences(of: " ", with: "·")
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\n", with: "↵")
    }
    static func compute(before: String, after: String) throws -> Result {
        try Task.checkCancellation()
        let a = lines(before), b = lines(after)
        var rows: [Row] = []
        var old = 0, new = 0
        var degraded = false
        func append(_ kind: Kind, _ raw: String) {
            if kind != .addition { old += 1 }
            if kind != .deletion { new += 1 }
            rows.append(Row(id: rows.count, kind: kind, oldNumber: kind == .addition ? nil : old,
                            newNumber: kind == .deletion ? nil : new, raw: raw,
                            runs: [Run(text: raw, emphasized: false)]))
        }
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] {
            if prefix % 256 == 0 { try Task.checkCancellation() }
            append(.context, a[prefix]); prefix += 1
        }
        var endA = a.count, endB = b.count
        while endA > prefix, endB > prefix, a[endA - 1] == b[endB - 1] {
            endA -= 1; endB -= 1
        }
        let n = endA - prefix, m = endB - prefix
        // Deterministic memory/work budget: at most 1,000,000 Int cells (~8 MiB).
        if (n + 1) * (m + 1) <= 1_000_000 {
            let width = m + 1
            var table = [Int](repeating: 0, count: (n + 1) * width)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    try Task.checkCancellation()
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i * width + j] = a[prefix + i] == b[prefix + j]
                            ? table[(i + 1) * width + j + 1] + 1
                            : max(table[(i + 1) * width + j], table[i * width + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if (i + j) % 256 == 0 { try Task.checkCancellation() }
                if i < n && j < m && a[prefix + i] == b[prefix + j] {
                    append(.context, a[prefix + i]); i += 1; j += 1
                } else if i < n && (j == m || table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                    append(.deletion, a[prefix + i]); i += 1
                } else { append(.addition, b[prefix + j]); j += 1 }
            }
        } else {
            degraded = true
            for i in prefix..<endA { if i % 256 == 0 { try Task.checkCancellation() }; append(.deletion, a[i]) }
            for j in prefix..<endB { if j % 256 == 0 { try Task.checkCancellation() }; append(.addition, b[j]) }
        }
        for i in endA..<a.count { append(.context, a[i]) }
        // Pair changed lines positionally, without comparing unrelated distant hunks.
        // Grapheme-safe common prefix/suffix emphasis: bounded and honest, not an edit script.
        var index = 0, inlineBudget = 200_000
        while index < rows.count {
            try Task.checkCancellation()
            guard rows[index].kind == .deletion else { index += 1; continue }
            let start = index
            while index < rows.count && rows[index].kind == .deletion { index += 1 }
            let added = index
            while index < rows.count && rows[index].kind == .addition { index += 1 }
            for offset in 0..<min(added - start, index - added) {
                let x = start + offset, y = added + offset
                let cost = rows[x].raw.utf8.count + rows[y].raw.utf8.count
                guard cost <= inlineBudget else { degraded = true; continue }
                inlineBudget -= cost
                let left = Array(rows[x].raw), right = Array(rows[y].raw)
                var p = 0, s = 0
                while p < min(left.count, right.count) && left[p] == right[p] { p += 1 }
                while s < min(left.count, right.count) - p && left[left.count - s - 1] == right[right.count - s - 1] { s += 1 }
                func runs(_ chars: [Character]) -> [Run] {
                    [Run(text: String(chars.prefix(p)), emphasized: false),
                     Run(text: String(chars[p..<(chars.count - s)]), emphasized: true),
                     Run(text: String(chars.suffix(s)), emphasized: false)]
                }
                rows[x].runs = runs(left); rows[y].runs = runs(right)
            }
        }
        var entries: [Entry] = [], changes: [Int] = []
        var shown = [Bool](repeating: false, count: rows.count)
        for i in rows.indices where rows[i].kind != .context {
            if i == 0 || rows[i - 1].kind == .context { changes.append(i) }
            for j in max(0, i - 3)..<min(rows.count, i + 4) { shown[j] = true }
        }
        var i = 0
        while i < rows.count {
            if i % 256 == 0 { try Task.checkCancellation() }
            if shown[i] { entries.append(.row(i)); i += 1 }
            else { let start = i; while i < rows.count && !shown[i] { i += 1 }; entries.append(.gap(start..<i)) }
        }
        let additions = rows.filter { $0.kind == .addition }.count
        let deletions = rows.filter { $0.kind == .deletion }.count
        let whitespaceOnly = before != after && before.filter { !$0.isWhitespace } == after.filter { !$0.isWhitespace }
        return Result(rows: rows, entries: entries, changes: changes, additions: additions,
                      deletions: deletions, whitespaceOnly: whitespaceOnly, degraded: degraded)
    }
}
