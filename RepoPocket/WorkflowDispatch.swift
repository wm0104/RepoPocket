import Foundation
import Combine

struct DispatchWorkflow: Decodable, Identifiable {
    let id: Int
    let name: String
    let path: String
    let state: String
}
struct DispatchWorkflows: Decodable { let workflows: [DispatchWorkflow] }
struct WorkflowDispatchSession: Equatable { let accountID: String; let generation: UUID }
struct WorkflowDispatchTarget: Identifiable {
    let id = UUID()
    let repo: String
    let workflow: DispatchWorkflow
    let ref: String
    var runTitle: String = ""
    let session: WorkflowDispatchSession
}
enum WorkflowDispatchRules {
    static let permissionHelp = "启动需要仓库写入权限及 Token 的 Actions: write 权限。请检查所选账号、仓库授权和组织 SSO；经典 Token 需相应 repo 授权。"
    static func check(status: Int, dispatch: Bool, bytes: Data) throws {
        if status == (dispatch ? 204 : 200) { return }
        let reason = (try? JSONDecoder().decode(GitHubMessage.self, from: bytes).message) ?? ""
        let help: String
        switch status {
        case 401: help = "登录凭据已失效，请重新登录当前账号。"
        case 403: help = permissionHelp + "也请检查 Actions 策略和 API 限流。"
        case 404: help = "仓库、工作流或分支不可访问，请刷新列表并检查私有仓库授权。" + permissionHelp
        case 422: help = "GitHub 拒绝启动：工作流可能未声明 workflow_dispatch、所选分支不支持手动运行、缺少必填 inputs，或该工作流没有声明 run_title 输入（删掉运行名称再试）。本界面仅使用默认输入，不支持填写额外参数；请到 GitHub 配置或运行。"
        default: help = dispatch ? "未收到 GitHub 的 204 接受确认，结果未知。请先刷新所选分支的 Actions 核实，勿盲目重试。" : "无法加载列表，请稍后手动刷新。"
        }
        throw AppError(text: "HTTP \(status)：\(help)\n\(reason)")
    }
}

@MainActor final class WorkflowDispatchState: ObservableObject {
    @Published private(set) var workflows: [DispatchWorkflow] = []
    @Published private(set) var branches: [DesktopBranch] = []
    @Published private(set) var loadingWorkflows = false
    @Published private(set) var loadingBranches = false
    @Published private(set) var moreWorkflows = true
    @Published private(set) var moreBranches = true
    @Published private(set) var busy = false
    @Published private(set) var attempted = false
    @Published private(set) var result = ""
    @Published private(set) var error = ""
    @Published var workflowID: Int?
    @Published var ref = ""
    @Published var runTitle = ""
    private var workflowPage = 1
    private var branchPage = 1
    private var session: WorkflowDispatchSession?
    private var repository: String?
    private var confirmation: UUID?

    private func bind(_ repo: String, api: GitHub) -> Bool {
        guard api.isCurrentSession else { return false }
        if session == nil { session = api.workflowDispatchSession; repository = repo }
        return session == api.workflowDispatchSession && repository == repo
    }
    func loadWorkflows(_ repo: String, api: GitHub) async {
        guard bind(repo, api: api), !loadingWorkflows, moreWorkflows, !attempted else { return }
        loadingWorkflows = true; error = ""
        defer { loadingWorkflows = false }
        do {
            let batch = try await api.dispatchWorkflows(repo, page: workflowPage)
            guard bind(repo, api: api), !Task.isCancelled else { return }
            // Count the unfiltered page: disabled workflows still occupy API pagination slots.
            moreWorkflows = batch.count == 100; workflowPage += 1
            var seen = Set(workflows.map(\.id))
            workflows += batch.filter { $0.id > 0 && seen.insert($0.id).inserted }
        } catch { if bind(repo, api: api), !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func loadBranches(_ repo: String, api: GitHub) async {
        guard bind(repo, api: api), !loadingBranches, moreBranches, !attempted else { return }
        loadingBranches = true; error = ""
        defer { loadingBranches = false }
        do {
            let batch = try await api.dispatchBranches(repo, page: branchPage)
            guard bind(repo, api: api), !Task.isCancelled else { return }
            moreBranches = batch.count == 100; branchPage += 1
            var seen = Set(branches.map(\.name))
            branches += batch.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
        } catch { if bind(repo, api: api), !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func target(_ repo: String, api: GitHub) -> WorkflowDispatchTarget? {
        guard bind(repo, api: api), !busy, !attempted,
              let workflow = workflows.first(where: { $0.id == workflowID && $0.state == "active" }),
              branches.contains(where: { $0.name == ref }) else { return nil }
        let target = WorkflowDispatchTarget(repo: repo, workflow: workflow, ref: ref,
                                             runTitle: String(runTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                                             session: api.workflowDispatchSession)
        confirmation = target.id
        return target
    }
    func submit(_ target: WorkflowDispatchTarget, api: GitHub, accepted: (String) -> Void) async {
        guard bind(target.repo, api: api), target.session == session, confirmation == target.id,
              !busy, !attempted, workflowID == target.workflow.id, ref == target.ref,
              runTitle.trimmingCharacters(in: .whitespacesAndNewlines) == target.runTitle else { return }
        // Consume confirmation before the first suspension; never auto-retry an uncertain POST.
        confirmation = nil; busy = true; attempted = true; error = ""; result = ""
        defer { busy = false }
        do {
            try await api.dispatchWorkflow(target)
            guard bind(target.repo, api: api), !Task.isCancelled else { return }
            result = "GitHub 已接受启动请求。运行可能稍后才出现在分支列表中；尚未关联到具体 run，请稍后刷新。"
            accepted(target.ref)
        } catch {
            guard bind(target.repo, api: api), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
