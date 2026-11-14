import Foundation

enum CommunityMutation {
    case createIssue, comment(Int), state(Int, String), merge(Int, String), cancelRun(Int), rerun(Int), rerunFailedJobs(Int), deleteRun(Int)
    var workflowRunOperation: WorkflowRunOperation? {
        switch self {
        case .cancelRun: return .cancel
        case .rerun: return .rerunAll
        case .rerunFailedJobs: return .rerunFailedJobs
        case .deleteRun: return .delete
        default: return nil
        }
    }
    var workflowRunID: Int? {
        switch self {
        case .cancelRun(let id), .rerun(let id), .rerunFailedJobs(let id), .deleteRun(let id): return id
        default: return nil
        }
    }
}
struct CommunityMutationRequest {
    let suffix: String
    let method: String
    let requiresPush: Bool
    let body: [String: Any]
}
enum CommunityMutationRules {
    static func request(_ action: CommunityMutation, title: String = "", text: String = "") throws -> CommunityMutationRequest {
        func positive(_ id: Int) throws { guard id > 0 else { throw AppError(text: "无效的操作编号") } }
        switch action {
        case .createIssue:
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 256, text.utf8.count <= 60_000 else { throw AppError(text: "请填写不超过256字的标题，正文须小于60 KB。") }
            return .init(suffix: "/issues", method: "POST", requiresPush: false, body: ["title": clean, "body": text])
        case .comment(let id):
            try positive(id)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 60_000 else { throw AppError(text: "评论不能为空，且须小于60 KB。") }
            return .init(suffix: "/issues/\(id)/comments", method: "POST", requiresPush: false, body: ["body": text])
        case .state(let id, let state):
            try positive(id); guard ["open", "closed"].contains(state) else { throw AppError(text: "无效议题状态") }
            return .init(suffix: "/issues/\(id)", method: "PATCH", requiresPush: false, body: ["state": state])
        case .merge(let id, let sha):
            try positive(id); guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit }) else { throw AppError(text: "未取得 PR 的确切提交，不能合并。") }
            return .init(suffix: "/pulls/\(id)/merge", method: "PUT", requiresPush: true, body: ["sha": sha, "merge_method": "merge"])
        case .cancelRun(let id):
            try positive(id); return .init(suffix: "/actions/runs/\(id)/cancel", method: "POST", requiresPush: true, body: [:])
        case .rerun(let id):
            try positive(id); return .init(suffix: "/actions/runs/\(id)/rerun", method: "POST", requiresPush: true, body: [:])
        case .rerunFailedJobs(let id):
            try positive(id); return .init(suffix: "/actions/runs/\(id)/rerun-failed-jobs", method: "POST", requiresPush: true, body: [:])
        case .deleteRun(let id):
            try positive(id); return .init(suffix: "/actions/runs/\(id)", method: "DELETE", requiresPush: true, body: [:])
        }
    }
}
enum WorkflowRunOperation: Equatable {
    case rerunFailedJobs, rerunAll, cancel, delete
    var isRerun: Bool { self == .rerunFailedJobs || self == .rerunAll }
    var title: String {
        switch self {
        case .rerunFailedJobs: return "仅重新运行失败的任务"
        case .rerunAll: return "重新运行全部任务"
        case .cancel: return "取消正在进行的运行"
        case .delete: return "删除此次运行"
        }
    }
    func mutation(_ id: Int) -> CommunityMutation {
        switch self {
        case .rerunFailedJobs: return .rerunFailedJobs(id)
        case .rerunAll: return .rerun(id)
        case .cancel: return .cancelRun(id)
        case .delete: return .deleteRun(id)
        }
    }
    func unavailability(status: String, conclusion: String?, createdAt: String?, now: Date = Date()) -> String? {
        if self == .cancel {
            return ["queued", "in_progress", "waiting", "requested", "pending"].contains(status) ? nil : "此运行已结束或状态未知，不能取消。"
        }
        guard status == "completed" else { return "此运行尚未结束，请等待结束并刷新后再操作。" }
        if isRerun {
            guard let created = WorkflowTime.date(createdAt), created <= now else { return "无法核实初次运行时间，请刷新后再试。" }
            guard now.timeIntervalSince(created) < 30 * 86400 else { return "此运行已超出 GitHub 的 30 天重新运行窗口。" }
        }
        // A cancelled run may contain failed jobs; only GitHub can decide the eligible set.
        if self == .rerunFailedJobs && !["failure", "timed_out", "cancelled"].contains(conclusion ?? "") {
            return "此运行没有可确认的失败、超时或取消结果；无法请求重新运行失败任务。"
        }
        return nil
    }
}

struct WorkflowRunActionTarget: Identifiable {
    let id = UUID()
    let repo: String
    let run: WorkflowRun
    let operation: WorkflowRunOperation
    let generation: UUID
    func validate(current: WorkflowRun, generation: UUID, sessionMatches: Bool, canWrite: Bool,
                  cancellationWaiting: Bool, now: Date = Date()) throws {
        guard sessionMatches, self.generation == generation else { throw AppError(text: "账号已变更，请重新打开此运行并确认。") }
        guard canWrite else { throw AppError(text: "当前账号没有已确认的 Actions 写入权限。") }
        guard !cancellationWaiting else { throw AppError(text: "正在等待取消结果，请先刷新核实运行状态。") }
        guard run.id > 0, current.id == run.id, current.run_number == run.run_number, current.head_sha == run.head_sha,
              current.run_attempt == run.run_attempt else { throw AppError(text: "运行或尝试次数已变更，请刷新后重新确认。") }
        if let reason = operation.unavailability(status: current.status, conclusion: current.conclusion, createdAt: current.created_at, now: now) {
            throw AppError(text: reason)
        }
    }
}

struct WorkflowRuns: Decodable { let workflow_runs: [WorkflowRun] }
struct WorkflowCancellationState {
    private(set) var requested = false
    private(set) var waiting = false
    private(set) var message = ""
    mutating func begin() -> Bool {
        guard !requested else { return false }
        requested = true
        return true
    }
    mutating func accepted() {
        waiting = true
        message = "GitHub 已接受取消请求，正在等待运行结束；清理可能需要几分钟，无需重复取消。"
    }
    mutating func uncertain(_ reason: String) {
        waiting = true
        message = reason + "\n尚未确认取消结果，正在刷新核实；请勿重复发送取消请求。"
    }
    mutating func observe(status: String, conclusion: String?) {
        guard requested, status == "completed" else { return }
        waiting = false
        message = conclusion == "cancelled" ? "运行已取消。" : "运行已结束：" + WorkflowStatusPresentation(status: status, conclusion: conclusion).title + "。"
    }
    mutating func stopWaiting() {
        waiting = false
        message = "尚未确认运行结束。GitHub 可能仍在清理，请稍后刷新核实；不会重复发送取消请求。"
    }
}
struct WorkflowStatusPresentation {
    let title: String
    let symbol: String
    let tone: String
    init(status: String, conclusion: String?) {
        switch status == "completed" ? (conclusion ?? "unknown") : status {
        case "success": (title, symbol, tone) = ("成功", "checkmark.circle.fill", "green")
        case "failure", "startup_failure": (title, symbol, tone) = ("失败", "xmark.circle.fill", "red")
        case "timed_out": (title, symbol, tone) = ("超时失败", "xmark.circle.fill", "red")
        case "action_required": (title, symbol, tone) = ("需要处理", "exclamationmark.circle.fill", "orange")
        case "in_progress": (title, symbol, tone) = ("运行中", "clock.fill", "orange")
        case "queued", "waiting", "requested", "pending": (title, symbol, tone) = ("等待运行", "clock", "gray")
        case "cancelled": (title, symbol, tone) = ("已取消", "minus.circle.fill", "gray")
        case "skipped": (title, symbol, tone) = ("已跳过", "arrow.right.circle", "gray")
        case "neutral": (title, symbol, tone) = ("已完成 · 中性结果", "circle", "gray")
        default: (title, symbol, tone) = ("状态未知", "questionmark.circle", "gray")
        }
    }
}
struct WorkflowRun: Decodable, Identifiable {
    let id: Int
    let name: String?
    let display_title: String?
    let head_commit: HeadCommit?
    struct HeadCommit: Decodable { let message: String? }
    var title: String {
        let subject = head_commit?.message?.components(separatedBy: .newlines).first
        return [display_title, subject, name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Workflow"
    }
    let run_number: Int
    var run_attempt: Int? = nil
    let head_branch: String?
    let head_sha: String
    let status: String
    let conclusion: String?
    let created_at: String
    let run_started_at: String?
    let updated_at: String?
    let event: String?
    let actor: Actor?
    struct Actor: Decodable { let login: String; let avatar_url: String? }
}
struct WorkflowJobs: Decodable { let jobs: [WorkflowJob] }
struct WorkflowArtifacts: Decodable { let artifacts: [WorkflowArtifact]; let total_count: Int? }
struct WorkflowArtifact: Decodable, Identifiable {
    let id: Int
    let name: String
    let size_in_bytes: Int
    let expired: Bool
}
struct WorkflowJob: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let started_at: String?
    let completed_at: String?
    let steps: [Step]?
    var run_attempt: Int? = nil
    struct Step: Decodable, Identifiable {
        let number: Int
        let name: String
        let status: String
        let conclusion: String?
        let started_at: String?
        let completed_at: String?
        var id: Int { number }
    }
}

enum WorkflowTime {
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
    static func elapsed(start: String?, end: String?, running: Bool, now: Date = Date()) -> String? {
        guard let start = date(start), start.timeIntervalSince1970 >= 0,
              let finish = running ? now : date(end), finish >= start else { return nil }
        let seconds = Int(finish.timeIntervalSince(start))
        if seconds >= 86400 { return "\(seconds / 86400)天\(seconds % 86400 / 3600)小时" }
        if seconds >= 3600 { return "\(seconds / 3600)小时\(seconds % 3600 / 60)分" }
        if seconds >= 60 { return "\(seconds / 60)分\(seconds % 60)秒" }
        return "\(seconds)秒"
    }
    static func trigger(_ event: String?) -> String {
        switch event {
        case "workflow_dispatch": return "手动触发"
        case "push": return "推送触发"
        case "pull_request", "pull_request_target": return "拉取请求触发"
        case "schedule": return "定时触发"
        case "release": return "发行版触发"
        case "workflow_run": return "工作流触发"
        default: return event ?? "触发方式未知"
        }
    }
}
struct StarTimestamp: Decodable { let starred_at: String; let user: User? }
struct CodeTree: Decodable {
    let tree: [File]
    let truncated: Bool?
    struct File: Decodable { let path: String; let type: String; let size: Int? }
}
struct CodeLineSummary { let files: Int; let lines: Int; let skipped: Int; let treeTruncated: Bool }
enum NativeStatisticsRules {
    static let extensions = Set(["swift", "m", "mm", "h", "c", "cpp", "hpp", "js", "jsx", "ts", "tsx", "py", "go", "rs", "java", "kt", "sh", "rb", "dart", "cs", "css", "html", "json", "yml", "yaml"])
    static func lineCount(_ text: String) -> Int { text.isEmpty ? 0 : text.filter { $0 == "\n" }.count + (text.hasSuffix("\n") ? 0 : 1) }
}
