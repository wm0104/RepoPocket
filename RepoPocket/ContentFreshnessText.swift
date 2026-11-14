import SwiftUI

struct ContentFreshnessText: View {
    let updatedAt: Date?
    let updating: Bool
    var error = ""
    var body: some View {
        if let updatedAt {
            HStack(spacing: 6) {
                if updating { ProgressView().scaleEffect(0.8) }
                Text("上次更新 " + ChinaDate.dateTime(updatedAt))
                if updating { Text("· 检查中") }
                else if !error.isEmpty { Text("· 尚未更新").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("content-freshness")
        }
    }
}
