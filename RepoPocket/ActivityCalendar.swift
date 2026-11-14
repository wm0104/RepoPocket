import Foundation
import Combine

struct ActivityDay: Identifiable {
    let date: Date
    let count: Int?
    let complete: Bool
    let events: [CommunityEvent]
    var id: String { ChinaDate.day(date) }
    var title: String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ChinaDate.timeZone
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }
    var detail: String {
        guard let count else { return "尚未加载该日期的数据" }
        return complete ? "已加载 \(count) 条公开活动" : "已加载至少 \(count) 条，当前日期数据不完整"
    }
}

enum ActivityCalendar {
    static func recordRange(_ events: [CommunityEvent]) -> String? {
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = events.compactMap { event -> Date? in
            guard let raw = event.created_at else { return nil }
            return plain.date(from: raw) ?? fractional.date(from: raw)
        }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return ChinaDate.day(first) + " — " + ChinaDate.day(last)
    }
    static func days(events: [CommunityEvent], exhausted: Bool, now: Date) -> [ActivityDay] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ChinaDate.timeZone
        let today = calendar.startOfDay(for: now)
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>()
        let unique = events.filter { seen.insert($0.id).inserted }
        let dated = unique.compactMap { event -> (CommunityEvent, Date)? in
            guard let raw = event.created_at, let date = plain.date(from: raw) ?? fractional.date(from: raw), date <= now else { return nil }
            return (event, date)
        }
        let valid = dated.count == unique.count
        let oldest = dated.map { calendar.startOfDay(for: $0.1) }.min()
        let grouped = Dictionary(grouping: dated, by: { ChinaDate.day($0.1) })
        return (-29...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let rows = grouped[ChinaDate.day(date), default: []].map { $0.0 }
            // The oldest day may be split across pages. Never turn an unloaded
            // day into zero, including when the 300-event budget was reached.
            let complete = valid && (exhausted || oldest.map { date > $0 } == true)
            return ActivityDay(date: date, count: rows.isEmpty ? (complete ? 0 : nil) : rows.count,
                               complete: complete, events: rows)
        }
    }
}

@MainActor final class ActivityCalendarStore: ObservableObject {
    @Published private(set) var items: [CommunityEvent] = []
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var attempted = false
    @Published private(set) var exhausted = false
    @Published private(set) var limited = false
    @Published private(set) var error = ""
    @Published private(set) var recordRange: String?
    private var page = 1
    private var generation = UUID()
    private var task: Task<Void, Never>?
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func load(refresh: Bool = false, api: GitHub, login: String) {
        guard api.isCurrentSession else { return }
        if refresh {
            cancel(); items = []; page = 1; exhausted = false; limited = false; loaded = false; recordRange = nil
        }
        guard !busy, !exhausted, !limited else { return }
        let request = generation
        attempted = true; busy = true; error = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.busy = false; self.task = nil } }
            do {
                for _ in 0..<3 {
                    try Task.checkCancellation()
                    let batch = try await api.communityEvents(login, page: self.page)
                    try Task.checkCancellation()
                    guard self.generation == request, api.isCurrentSession else { return }
                    guard batch.count <= CommunityRules.pageSize else { throw AppError(text: "活动响应超过分页限制，请重试。") }
                    var ids = Set(self.items.map(\.id))
                    self.items += batch.filter { ids.insert($0.id).inserted }
                    self.recordRange = ActivityCalendar.recordRange(self.items)
                    self.page += 1; self.loaded = true
                    self.exhausted = batch.count < CommunityRules.pageSize
                    self.limited = !self.exhausted && self.page > CommunityRules.pageLimit
                    if self.exhausted || self.limited { break }
                }
            } catch {
                guard self.generation == request, api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
