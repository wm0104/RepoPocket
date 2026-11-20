import SwiftUI

struct DownloadProgressRing: View {
    let fraction: Double?
    var active: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    private var value: Double? { fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
    private var shouldRotate: Bool { active && value != 1 && !reduceMotion }
    private func elapsed(at date: Date) -> TimeInterval {
        elapsed + (startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
    private func rotate(_ running: Bool) {
        let now = Date()
        if running, startedAt == nil { startedAt = now }
        else if !running, startedAt != nil { elapsed = elapsed(at: now); startedAt = nil }
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: startedAt == nil)) { context in
            ZStack {
                Circle().strokeBorder(Color(uiColor: .systemGray5), lineWidth: 2)
                Circle().inset(by: 1).trim(from: 0, to: value ?? 0.24)
                    .stroke(Color(uiColor: .systemBlue), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(elapsed(at: context.date).truncatingRemainder(dividingBy: 1.6) / 1.6 * 360 - 90))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("下载进度")
        .accessibilityValue(value.map { "已接收 \(Int(($0 * 100).rounded(.down)))%" } ?? "总大小未知")
        .onAppear { rotate(shouldRotate) }
        .onChange(of: shouldRotate) { rotate($0) }
        .onDisappear { rotate(false) }
    }
}

struct DownloadProgressRow: View {
    let name: String
    let progress: ReleaseDownloadProgress?
    var status: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                else if let progress { Text(progress.label).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            DownloadProgressRing(fraction: progress?.fraction)
        }
    }
}
