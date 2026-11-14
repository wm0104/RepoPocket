import SwiftUI

struct RepositoryUpdatedText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.formatter.localizedString(for: date, relativeTo: context.date) + "更新")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("仓库更新于 " + ChinaDate.dateTime(date))
        }
    }
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
