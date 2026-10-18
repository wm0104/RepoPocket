import Foundation

/// Every visible date/time in RepoPocket renders in China time with a
/// 12-hour clock, regardless of the device region or 24-hour setting.
enum ChinaDate {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// "2026-10-18 下午 2:29"
    static func dateTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let y = p.year, let mo = p.month, let d = p.day, let h = p.hour, let mi = p.minute else { return "时间未知" }
        let suffix = h < 12 ? "上午" : "下午"
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%04d-%02d-%02d %@ %d:%02d", y, mo, d, suffix, hour12, mi)
    }

    static func dateTime(_ value: String?) -> String {
        guard let date = parse(value) else { return value ?? "时间未知" }
        return dateTime(date)
    }

    /// "2026-10-18"
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = p.year, let mo = p.month, let d = p.day else { return "未知日期" }
        return String(format: "%04d-%02d-%02d", y, mo, d)
    }

    static func day(_ value: String?) -> String {
        guard let date = parse(value) else { return String((value ?? "未知日期").prefix(10)) }
        return day(date)
    }

    /// "2026-10" for month grouping.
    static func month(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month], from: date)
        guard let y = p.year, let mo = p.month else { return "未知月份" }
        return String(format: "%04d-%02d", y, mo)
    }

    static func month(_ value: String?) -> String {
        guard let date = parse(value) else { return String((value ?? "未知月份").prefix(7)) }
        return month(date)
    }
}
