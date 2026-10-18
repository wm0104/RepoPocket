import SwiftUI

/// A small timer subtree; completed rows do not keep a per-second timeline alive.
struct WorkflowElapsedText: View {
    let start: String?
    let end: String?
    let status: String
    var approximate = false
    var body: some View {
        if status == "in_progress" {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(WorkflowTime.elapsed(start: start, end: nil, running: true, now: context.date) ?? "—")
            }
        } else {
            Text(value)
        }
    }
    private var value: String {
        guard status == "completed" else { return "等待运行" }
        guard let result = WorkflowTime.elapsed(start: start, end: end, running: false) else { return "—" }
        return (approximate ? "约" : "") + result
    }
}

struct WorkflowCreatedText: View {
    let timestamp: String
    var body: some View {
        if let date = WorkflowTime.date(timestamp) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(relative(date, now: context.date))
            }.accessibilityLabel("创建时间：" + timestamp)
        } else { Text("创建时间未知") }
    }
    private func relative(_ date: Date, now: Date) -> String {
        Self.formatter.localizedString(for: date, relativeTo: now)
    }
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct WorkflowRunHeading: View {
    let repo: String
    let run: WorkflowRun
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(repo + " / " + (run.name ?? "Actions")).font(.caption).foregroundStyle(.secondary)
            Text(run.display_title ?? run.name ?? "Workflow").font(.title2.bold())
            Text((run.name ?? "Workflow") + " #\(run.run_number)").font(.title3).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}

struct WorkflowRunMetadata: View {
    let run: WorkflowRun
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.crop.circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text((run.actor?.login ?? "未知用户") + " · " + WorkflowTime.trigger(run.event))
                    WorkflowCreatedText(timestamp: run.created_at)
                }
            }.font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { commit; branch }
                VStack(alignment: .leading, spacing: 8) { commit; branch }
            }
        }.padding(.vertical, 4)
    }
    private var commit: some View {
        Label(String(run.head_sha.prefix(7)), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .accessibilityLabel("提交：" + run.head_sha)
    }
    private var branch: some View {
        Label(run.head_branch ?? "分支未知", systemImage: "arrow.triangle.branch")
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WorkflowRunMetrics: View {
    @ObservedObject var api: GitHub
    let repo: String
    let run: WorkflowRun
    let artifactCount: Int?
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { status; Divider(); duration; Divider(); artifacts }
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) { status; duration; artifacts }
        }.padding(.vertical, 6)
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("状态").font(.caption).foregroundStyle(.secondary)
            WorkflowStatusBadge(status: run.status, conclusion: run.conclusion).font(.subheadline)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var duration: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("持续时间").font(.caption).foregroundStyle(.secondary)
            WorkflowElapsedText(start: run.run_started_at, end: run.updated_at, status: run.status, approximate: true).font(.subheadline)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var artifacts: some View {
        NavigationLink { WorkflowArtifactsView(api: api, repo: repo, run: run.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text("构建产物").font(.caption).foregroundStyle(.secondary)
                Label(artifactCount.map(String.init) ?? "查看", systemImage: "shippingbox").font(.subheadline)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WorkflowJobRow: View {
    let job: WorkflowJob
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name).font(.headline)
            WorkflowStatusBadge(status: job.status, conclusion: job.conclusion).font(.subheadline)
            WorkflowElapsedText(start: job.started_at, end: job.completed_at, status: job.status)
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}

struct WorkflowStepRow: View {
    let step: WorkflowJob.Step
    let expanded: Bool
    let toggle: () -> Void
    var output: AnyView? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(step.number). " + step.name).foregroundStyle(.primary)
                        WorkflowStatusBadge(status: step.status, conclusion: step.conclusion).font(.caption)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("持续时间"); Spacer(); WorkflowElapsedText(start: step.started_at, end: step.completed_at, status: step.status) }
                    if let start = WorkflowTime.date(step.started_at) { LabeledContent("开始", value: ChinaDate.dateTime(start)) }
                    if let end = WorkflowTime.date(step.completed_at) { LabeledContent("结束", value: ChinaDate.dateTime(end)) }
                    if let output { output }
                }.font(.caption)
            }
        }.padding(.vertical, 4)
    }
}
