import Foundation

struct SourceTextEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

enum SourceEditRules {
    static func newline(_ text: String, selection: NSRange) -> SourceTextEdit? {
        let source = text as NSString
        guard valid(selection, in: source) else { return nil }
        let start = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let prefix = source.substring(with: NSRange(location: start, length: selection.location - start))
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let firstLF = source.range(of: "\n").location
        let ending: String
        if firstLF != NSNotFound { ending = firstLF > 0 && source.character(at: firstLF - 1) == 13 ? "\r\n" : "\n" }
        else { ending = text.contains("\r") ? "\r" : "\n" }
        let replacement = ending + indentation
        return SourceTextEdit(range: selection, replacement: replacement,
                              selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
    }

    static func indent(_ text: String, selection: NSRange, unindent: Bool) -> SourceTextEdit? {
        let source = text as NSString
        guard valid(selection, in: source) else { return nil }
        if selection.length == 0 && !unindent {
            return SourceTextEdit(range: selection, replacement: "    ", selection: NSRange(location: selection.location + 4, length: 0))
        }
        // A selection ending at the next line's start must not indent that line.
        let lines = source.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        var cursor = lines.location, replacement = ""
        var start = selection.location, end = NSMaxRange(selection)
        while cursor < NSMaxRange(lines) {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            let value = source.substring(with: line)
            let removed = unindent ? (value.hasPrefix("\t") ? 1 : value.prefix(4).prefix { $0 == " " }.count) : 0
            let added = unindent ? 0 : 4
            replacement += (unindent ? "" : "    ") + (value as NSString).substring(from: removed)
            if selection.location >= cursor { start += added - min(removed, selection.location - cursor) }
            if NSMaxRange(selection) >= cursor { end += added - min(removed, NSMaxRange(selection) - cursor) }
            cursor = NSMaxRange(line)
        }
        guard replacement != source.substring(with: lines) else { return nil }
        return SourceTextEdit(range: lines, replacement: replacement, selection: NSRange(location: start, length: end - start))
    }
    private static func valid(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= text.length,
              range.length <= text.length - range.location else { return false }
        // Foundation range bridging can accept an offset inside a surrogate pair.
        return [range.location, NSMaxRange(range)].allSatisfy { offset in
            offset == text.length || !(0xDC00...0xDFFF).contains(text.character(at: offset))
        }
    }
}
