import Foundation

@main struct SourceTextSearchFixture {
    static func main() async {
        func matches(_ text: String, _ term: String, matchCase: Bool = false) -> [NSRange] {
            var ranges: [NSRange] = []
            SourceTextSearch.enumerate(text, term: term, matchCase: matchCase) { ranges.append($0); return true }
            return ranges
        }
        precondition(matches("Aa aA aa", "aa").count == 3)
        precondition(matches("Aa aA aa", "aa", matchCase: true) == [NSRange(location: 6, length: 2)])
        precondition(matches("aaaaa", "aa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        precondition(matches("a.b axb", "a.b") == [NSRange(location: 0, length: 3)])
        precondition(matches("anything", "").isEmpty && matches("", "anything").isEmpty)
        precondition(matches("😀中文😀中文", "中文") == [NSRange(location: 2, length: 2), NSRange(location: 6, length: 2)])
        precondition(matches("😀中文😀中文", "😀") == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        precondition(matches("café cafe\u{301}", "café").count == 2)
        var stopped = 0
        SourceTextSearch.enumerate("a a a", term: "a", matchCase: false) { _ in stopped += 1; return false }
        precondition(stopped == 1)
        let value = "巨魔 😀 巨魔 巨魔"
        let first = SourceTextSearch.find(value, term: "巨魔", matchCase: false, selection: NSRange(location: 0, length: 0), forwards: true)!
        precondition(first.range == NSRange(location: 0, length: 2) && first.index == 1 && first.count == 3)
        let second = SourceTextSearch.find(value, term: "巨魔", matchCase: false, selection: first.range, forwards: true)!
        precondition(second.range == NSRange(location: 6, length: 2) && second.index == 2)
        let last = SourceTextSearch.find(value, term: "巨魔", matchCase: false, selection: first.range, forwards: false)!
        precondition(last.range == NSRange(location: 9, length: 2) && last.index == 3)
        precondition(SourceTextSearch.find(value, term: "巨魔", matchCase: false, selection: last.range, forwards: true)!.range == first.range)
        precondition(SourceTextSearch.find(value, term: "巨魔", matchCase: false, selection: second.range, forwards: nil)!.range == second.range)
        precondition(SourceTextSearch.find("cat", term: "dog", matchCase: false, selection: first.range, forwards: nil) == nil)
        let changed = SourceTextSearch.find("😀 Aa aa", term: "aa", matchCase: true, selection: NSRange(location: 0, length: 0), forwards: nil)!
        precondition(changed.count == 1 && changed.range == NSRange(location: 6, length: 2))
        let many = SourceTextSearch.find(String(repeating: "a ", count: 3000), term: "a", matchCase: false,
                                         selection: NSRange(location: 5996, length: 1), forwards: true)!
        precondition(many.count == 3000 && many.index == 3000 && many.range.location == 5998)
        precondition(many.highlights.count == 2001 && many.highlights.last == many.range)
        let only = SourceTextSearch.find("a a", term: "a", matchCase: false, selection: NSRange(location: 0, length: 1), forwards: true, highlightLimit: 0)!
        precondition(only.highlights == [NSRange(location: 2, length: 1)])
        let ranges = SourceTextSearch.replacementRanges("cat cat", term: "cat", matchCase: false)!
        precondition(SourceTextSearch.replacing("cat cat", ranges: ranges, with: "catcat", byteLimit: 20) == "catcat catcat")
        precondition(SourceTextSearch.replacing("cat cat", ranges: ranges, with: "", byteLimit: 1) == " ")
        precondition(SourceTextSearch.replacementRanges("a a a", term: "a", matchCase: false, limit: 2) == nil)
        precondition(SourceTextSearch.replacementRanges("a a", term: "a", matchCase: false, limit: 2)!.count == 2)
        precondition(SourceTextSearch.replacementRanges(String(repeating: "a", count: 100_001), term: "a", matchCase: false) == nil)
        let unicode = "😀中文😀中文", unicodeRanges = matches(unicode, "中文")
        precondition(SourceTextSearch.replacing(unicode, ranges: unicodeRanges, with: "é", byteLimit: 12) == "😀é😀é")
        precondition(SourceTextSearch.replacing(unicode, ranges: unicodeRanges, with: "é", byteLimit: 11) == nil)
        let limit = 1024 * 1024
        let budgetRanges = [NSRange(location: 0, length: 1)]
        precondition(SourceTextSearch.replacing("a", ranges: budgetRanges, with: String(repeating: "x", count: limit), byteLimit: limit) != nil)
        precondition(SourceTextSearch.replacing("a", ranges: budgetRanges, with: String(repeating: "x", count: limit + 1), byteLimit: limit) == nil)
        precondition(SourceTextSearch.fitsReplacement("a", ranges: budgetRanges, replacement: "😀", byteLimit: 4))
        precondition(!SourceTextSearch.fitsReplacement("a", ranges: budgetRanges, replacement: "😀", byteLimit: 3))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return SourceTextSearch.find("a a a", term: "a", matchCase: false, selection: NSRange(location: 0, length: 0), forwards: nil)
        }
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)
        print("PASS production literal/case/UTF16/canonical matches, wrap/count/decorations, replacement atomicity/UTF8 budgets, cancellation")
    }
}
