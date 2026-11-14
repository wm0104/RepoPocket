import Foundation

/// Keep transport text exact; only the display projection removes terminal CSI sequences.
struct WorkflowLogPresentation: Sendable {
    enum Severity: Equatable, Sendable { case error, warning }
    struct Line: Equatable, Sendable {
        let range: NSRange
        let rawRange: NSRange
        let number: Int
        let severity: Severity
        let isExitSummary: Bool
    }
    let rawText: String
    let displayText: String
    let lines: [Line]
    let errorCount: Int
    let warningCount: Int
    let errorLocations: [Line]
    let onlyExitSummary: Bool

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let marker = try! NSRegularExpression(pattern:
        #"^[ \t]*(?:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z[ \t]+)?(?:##\[(error|warning)\]|::(error|warning)(?:[ \t]+.*?)?::|(ERROR:))"#)
    private static let diagnostic = try! NSRegularExpression(pattern:
        #"^[ \t]*(?:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z[ \t]+)?(?:[^\r\n]+:[0-9]+(?::[0-9]+)?:[ \t]*(?:fatal[ \t]+)?error:|Traceback \(most recent call last\):[ \t]*$)"#)
    private static let exitSummary = try! NSRegularExpression(pattern:
        #"^(?:Error:[ \t]*)?(?:Process completed with exit code [0-9]+\.?|The process '.+' failed with exit code [0-9]+\.?)[ \t]*$"#,
        options: .caseInsensitive)

    init(rawText: String) throws {
        try Task.checkCancellation()
        let text = Self.ansi.stringByReplacingMatches(in: rawText,
            range: NSRange(location: 0, length: rawText.utf16.count), withTemplate: "")
        let source = text as NSString, original = rawText as NSString
        var lines: [Line] = [], location = 0, rawLocation = 0, number = 1, errors = 0, warnings = 0
        while location < source.length {
            try Task.checkCancellation()
            var start = 0, end = 0, contentEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: start, length: contentEnd - start)
            let line = source.substring(with: range)
            var rawStart = 0, rawEnd = 0, rawContentEnd = 0
            original.getLineStart(&rawStart, end: &rawEnd, contentsEnd: &rawContentEnd, for: NSRange(location: rawLocation, length: 0))
            let whole = NSRange(location: 0, length: range.length)
            let match = Self.marker.firstMatch(in: line, range: whole)
            if match != nil || Self.diagnostic.firstMatch(in: line, range: whole) != nil {
                let warning = match.map {
                    let command = $0.range(at: 1).location != NSNotFound ? $0.range(at: 1) : $0.range(at: 2)
                    return command.location != NSNotFound && (line as NSString).substring(with: command) == "warning"
                } ?? false
                let severity: Severity = warning ? .warning : .error
                let message = match.map { (line as NSString).substring(from: NSMaxRange($0.range)).trimmingCharacters(in: .whitespaces) } ?? line
                let summary = severity == .error && Self.exitSummary.firstMatch(in: message, range: NSRange(location: 0, length: message.utf16.count)) != nil
                lines.append(Line(range: range, rawRange: NSRange(location: rawStart, length: rawContentEnd - rawStart),
                                  number: number, severity: severity, isExitSummary: summary))
                if severity == .error { errors += 1 } else { warnings += 1 }
            }
            location = end; rawLocation = rawEnd; number += 1
        }
        self.rawText = rawText; displayText = text; self.lines = lines
        errorCount = errors; warningCount = warnings
        let allErrors = lines.filter { $0.severity == .error }
        let specific = allErrors.filter { !$0.isExitSummary }
        errorLocations = specific.isEmpty ? allErrors : specific
        onlyExitSummary = !allErrors.isEmpty && specific.isEmpty
    }
}
