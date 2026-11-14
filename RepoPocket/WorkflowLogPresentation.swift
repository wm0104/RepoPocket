import Foundation

/// Keep transport text exact; only the display projection removes terminal CSI sequences.
struct WorkflowLogPresentation: Sendable {
    enum Severity: Equatable, Sendable { case error, warning }
    struct Line: Equatable, Sendable {
        let range: NSRange
        let severity: Severity
    }
    let rawText: String
    let displayText: String
    let lines: [Line]
    let errorCount: Int
    let warningCount: Int

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let marker = try! NSRegularExpression(pattern:
        #"^[ \t]*(?:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z[ \t]+)?(?:##\[(error|warning)\]|::(error|warning)(?:[ \t]+.*?)?::|(ERROR:))"#)

    init(rawText: String) throws {
        try Task.checkCancellation()
        let text = Self.ansi.stringByReplacingMatches(in: rawText,
            range: NSRange(location: 0, length: rawText.utf16.count), withTemplate: "")
        let source = text as NSString
        var lines: [Line] = [], location = 0, errors = 0, warnings = 0
        while location < source.length {
            try Task.checkCancellation()
            var start = 0, end = 0, contentEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: start, length: contentEnd - start)
            let line = source.substring(with: range)
            if let match = Self.marker.firstMatch(in: line, range: NSRange(location: 0, length: range.length)) {
                let command = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                let severity: Severity = command.location == NSNotFound || (line as NSString).substring(with: command) == "error" ? .error : .warning
                lines.append(Line(range: range, severity: severity))
                if severity == .error { errors += 1 } else { warnings += 1 }
            }
            location = end
        }
        self.rawText = rawText; displayText = text; self.lines = lines
        errorCount = errors; warningCount = warnings
    }
}
