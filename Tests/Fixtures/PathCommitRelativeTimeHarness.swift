import Foundation

@main struct PathCommitRelativeTimeHarness {
    static func main() {
        NSTimeZone.default = TimeZone(secondsFromGMT: 8 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
        let cases: [(TimeInterval, String)] = [
            (-60, "刚刚"), (0, "刚刚"), (30, "刚刚"), (59.999, "刚刚"),
            (60, "1分钟前"), (119.999, "1分钟前"), (120, "2分钟前"),
            (2280, "38分钟前"), (3599.999, "59分钟前"),
            (3600, "1小时前"), (4980, "1小时前"), (82800, "23小时前"),
            (86399.999, "23小时前"), (86400, "昨天"),
            (172800, "前天"), (259200, "3天前"), (604800, "上周"), (1209600, "2周前")
        ]
        for (elapsed, expected) in cases {
            let result = PathCommitRelativeTime.text(for: now.addingTimeInterval(-elapsed), now: now)
            precondition(result == expected, "\(elapsed): \(result) != \(expected)")
            precondition(!result.contains("秒"))
        }
        let calendarCases: [(Calendar.Component, Int, String)] = [
            (.month, -1, "上个月"), (.month, -2, "2个月前"),
            (.year, -1, "去年"), (.year, -2, "2年前")
        ]
        for (unit, value, expected) in calendarCases {
            let date = calendar.date(byAdding: unit, value: value, to: now)!
            precondition(PathCommitRelativeTime.text(for: date, now: now) == expected, expected)
        }
        print("PASS \(cases.count + calendarCases.count) relative-time boundaries")
    }
}
