// Adapted from Fila 04868b7, Copyright (c) 2026 OwnGoal Studio (MIT).
import Foundation

enum SourceTextSearch {
    struct Result: Sendable {
        let range: NSRange
        let index: Int
        let count: Int
        let highlights: [NSRange]
    }

    /// Only decorations are bounded; navigation and counts still include every match.
    /// A nil direction refreshes at the selection instead of advancing past it.
    static func find(_ text: String, term: String, matchCase: Bool, selection: NSRange,
                     forwards: Bool?, highlightLimit: Int = 2_000) -> Result? {
        var first: (range: NSRange, index: Int)?
        var last: (range: NSRange, index: Int)?
        var target: (range: NSRange, index: Int)?
        var count = 0
        var highlights: [NSRange] = []
        enumerate(text, term: term, matchCase: matchCase) { range in
            guard !Task.isCancelled else { return false }
            count += 1
            let match = (range, count)
            if first == nil { first = match }
            last = match
            if highlights.count < highlightLimit { highlights.append(range) }
            if forwards == false {
                if NSMaxRange(range) <= selection.location { target = match }
            } else if target == nil, range.location >= (forwards == true ? NSMaxRange(selection) : selection.location) {
                target = match
            }
            return true
        }
        guard !Task.isCancelled, let selected = target ?? (forwards == false ? last : first) else { return nil }
        if !highlights.contains(selected.range) { highlights.append(selected.range) }
        return Result(range: selected.range, index: selected.index, count: count, highlights: highlights)
    }

    static func enumerate(_ text: String, term: String, matchCase: Bool, body: (NSRange) -> Bool) {
        guard !term.isEmpty else { return }
        let source = text as NSString
        var position = 0
        while position < source.length {
            let match = source.range(
                of: term,
                options: matchCase ? [] : [.caseInsensitive],
                range: NSRange(location: position, length: source.length - position),
            )
            guard match.location != NSNotFound, match.length > 0, body(match) else { return }
            position = NSMaxRange(match)
        }
    }

    /// A partial batch must never be applied as though it replaced everything.
    static func replacementRanges(_ text: String, term: String, matchCase: Bool, limit: Int = 100_000) -> [NSRange]? {
        var ranges: [NSRange] = []
        var exceeded = false
        enumerate(text, term: term, matchCase: matchCase) { range in
            guard ranges.count < limit else {
                exceeded = true
                return false
            }
            ranges.append(range)
            return true
        }
        return exceeded ? nil : ranges
    }

    static func fitsReplacement(_ text: String, ranges: [NSRange], replacement: String, byteLimit: Int) -> Bool {
        let source = text as NSString
        let removed = ranges.reduce(0) { $0 + source.substring(with: $1).utf8.count }
        let remaining = text.utf8.count - removed
        guard remaining <= byteLimit else { return false }
        let added = replacement.utf8.count
        return added == 0 || ranges.count <= (byteLimit - remaining) / added
    }

    static func replacing(_ text: String, ranges: [NSRange], with replacement: String, byteLimit: Int) -> String? {
        guard fitsReplacement(text, ranges: ranges, replacement: replacement, byteLimit: byteLimit) else { return nil }
        let source = text as NSString
        var result = ""
        var position = 0
        for range in ranges {
            result += source.substring(with: NSRange(location: position, length: range.location - position))
            result += replacement
            position = NSMaxRange(range)
        }
        result += source.substring(from: position)
        return result
    }
}
