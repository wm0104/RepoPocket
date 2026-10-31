import SwiftUI

// Read-only answer of GET /repos/{owner}/{repo}/compare/{base}...{head}.
struct UpstreamCompare: Decodable {
    struct Commit: Decodable, Identifiable {
        struct Info: Decodable {
            struct Author: Decodable { let name: String?; let date: String? }
            let message: String
            let author: Author?
        }
        let sha: String
        let commit: Info
        var id: String { sha }
    }
    struct File: Decodable, Identifiable {
        let filename: String
        let additions: Int?
        let deletions: Int?
        var id: String { filename }
    }
    let status: String?
    let ahead_by: Int?
    let behind_by: Int?
    let total_commits: Int?
    let commits: [Commit]?
    let files: [File]?
}

/// Pure request shapes and answer mapping for upstream sync.
/// shortcut: only the three documented endpoints are modelled; add per-page
/// commit paging or conflict preview when someone needs more than the caps below.
enum UpstreamSyncRules {
    static let commitLimit = 30
    static let fileLimit = 100

    struct Invalid: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// A fully user-chosen upstream; nothing is preselected or hardcoded.
    struct Target: Equatable {
        let repository: String
        let branch: String
        var owner: String { String(repository.split(separator: "/").first ?? "") }
    }

    static func target(repository: String, branch: String) throws -> Target {
        let name = try RepositoryInput.parse(repository)
        let ref = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DesktopRules.validBranch(ref) else { throw Invalid(text: "上游分支名不符合 Git 引用规则。") }
        return Target(repository: name, branch: ref)
    }

    /// Suggestions from the repository's own parent/source links only.
    static func candidates(parent: String?, source: String?, current: String) -> [String] {
        var seen = Set<String>()
        return [parent, source].compactMap { $0 }.filter { value in
            (try? RepositoryInput.parse(value)) != nil
                && value.lowercased() != current.lowercased()
                && seen.insert(value.lowercased()).inserted
        }
    }

    // MARK: - Paths

    static func segment(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    static func repositoryPath(_ fullName: String) -> String {
        "/repos/" + fullName.split(separator: "/").map { segment(String($0)) }.joined(separator: "/")
    }
    /// Branch slashes stay literal; each segment is escaped.
    static func refPath(_ branch: String) -> String {
        branch.split(separator: "/").map { segment(String($0)) }.joined(separator: "/")
    }
    /// `{base}...{upstreamOwner}:{upstreamBranch}` — the cross-repository head form.
    static func comparePath(repo: String, base: String, upstream: Target) throws -> String {
        guard DesktopRules.validBranch(base) else { throw Invalid(text: "目标分支名不符合 Git 引用规则。") }
        return try repositoryPath(RepositoryInput.parse(repo)) + "/compare/" + refPath(base)
            + "..." + segment(upstream.owner) + ":" + refPath(upstream.branch)
    }
    static func mergesPath(repo: String) throws -> String {
        try repositoryPath(RepositoryInput.parse(repo)) + "/merges"
    }
    static func refsPath(repo: String) throws -> String {
        try repositoryPath(RepositoryInput.parse(repo)) + "/git/refs"
    }
    static func branchHeadPath(repo: String, branch: String) throws -> String {
        guard DesktopRules.validBranch(branch) else { throw Invalid(text: "目标分支名不符合 Git 引用规则。") }
        return try repositoryPath(RepositoryInput.parse(repo)) + "/git/ref/heads/" + refPath(branch)
    }
    static func branchRefPath(repo: String, branch: String) throws -> String {
        guard DesktopRules.validBranch(branch) else { throw Invalid(text: "目标分支名不符合 Git 引用规则。") }
        return try repositoryPath(RepositoryInput.parse(repo)) + "/git/refs/heads/" + refPath(branch)
    }

    // MARK: - Bodies

    static func refObject(ref: String, sha: String) -> [String: Any] { ["ref": ref, "sha": sha] }
    /// `base` is always the temporary branch; the target is never named here.
    static func mergeObject(base: String, upstream: Target, message: String) -> [String: Any] {
        ["base": base, "head": upstream.owner + ":" + upstream.branch, "commit_message": message]
    }
    static func applyObject(sha: String) -> [String: Any] { ["sha": sha, "force": false] }

    // MARK: - Names

    static func stamp(_ date: Date = Date(), timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
    static func backupTag(_ stamp: String) -> String { "backup/pre-sync-" + stamp }
    static func tempBranch(_ stamp: String) -> String { "sync/upstream-" + stamp }
    static func mergeMessage(targetBranch: String, upstream: Target, stamp: String) -> String {
        "Merge " + upstream.repository + " (" + upstream.branch + ") into " + targetBranch + " via RepoPocket " + stamp
    }
    static func validSHA(_ sha: String) -> Bool {
        sha.count == 40 && sha.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }

    // MARK: - Answers

    static func objectSHA(_ body: Data) -> String? {
        struct Ref: Decodable {
            struct Object: Decodable { let sha: String }
            let object: Object?
            let sha: String?
        }
        guard let ref = try? JSONDecoder().decode(Ref.self, from: body) else { return nil }
        guard let value = ref.object?.sha ?? ref.sha, validSHA(value) else { return nil }
        return value
    }
    static func message(_ body: Data) -> String? {
        struct Payload: Decodable { let message: String? }
        let text = (try? JSONDecoder().decode(Payload.self, from: body))?.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = text, !text.isEmpty else { return nil }
        return text
    }

    enum MergeOutcome: Equatable {
        case merged(sha: String)
        case upToDate
        case conflict
        case rejected(String)
    }
    /// 409 is the documented conflict answer and must stop the flow.
    static func mergeOutcome(status: Int, body: Data) -> MergeOutcome {
        if status == 409 { return .conflict }
        if status == 204 { return .upToDate }
        if (200..<300).contains(status) {
            guard let sha = objectSHA(body) else { return .rejected("GitHub 未返回合并提交，请到仓库核实后重试。") }
            return .merged(sha: sha)
        }
        return .rejected(message(body) ?? "HTTP \(status)")
    }

    enum ApplyOutcome: Equatable {
        case updated(sha: String)
        case rejected(String)
    }
    static func applyOutcome(status: Int, body: Data) -> ApplyOutcome {
        if (200..<300).contains(status), let sha = objectSHA(body) { return .updated(sha: sha) }
        let detail = (200..<300).contains(status) ? "GitHub 未确认分支更新，请刷新核实。" : (message(body) ?? "HTTP \(status)")
        return .rejected(detail + "\n" + "快进被拒绝时不会改写历史，目标分支与临时分支都会保留。请在电脑上检查差异后处理。")
    }

    // MARK: - Permissions

    static let permissionHelp = "此操作需要 Token 对目标仓库具备 Contents: write（读写内容）与 Metadata: read（只读元数据）权限。请在 GitHub 的细粒度 Token 中补充后重新保存账号。"
    static func permissionFailure(status: Int, operation: String, reason: String) -> String? {
        guard [401, 403, 404].contains(status) else { return nil }
        var text = "HTTP \(status) · \(operation)\n\(reason)\n"
        if status == 404 { text += "也可能是上游仓库或分支不存在，请先确认两者可访问。\n" }
        return text + permissionHelp
    }

    // MARK: - Remembered selection (only values the user confirmed)

    static func memoryKey(account: String, repository: String) -> String {
        "RepoPocket.upstreamSync.v1." + account + "." + repository.lowercased()
    }
    static func encodeMemory(repository: String, branch: String) -> String { repository + "\n" + branch }
    static func decodeMemory(_ text: String?) -> (repository: String, branch: String)? {
        guard let text = text else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 2, let target = try? target(repository: lines[0], branch: lines[1]) else { return nil }
        return (target.repository, target.branch)
    }
}

/// Preview (read-only) → merge into a temporary branch → optional fast-forward
/// apply. The target branch never moves before the last step, and no step can
/// force anything.
@MainActor final class UpstreamSyncState: ObservableObject {
    enum Stage: Equatable { case preview, merged, upToDate, conflict, failed, applied }
    struct Receipt: Equatable {
        let stamp: String
        let backupTag: String
        let tempBranch: String
        var head: String
        let upstream: String
        let upstreamBranch: String
    }

    @Published var upstreamRepository = ""
    @Published var upstreamBranch = ""
    @Published var compare: UpstreamCompare?
    @Published var error = ""
    @Published var busy = false
    @Published var loading = false
    @Published var stage: Stage = .preview
    @Published var receipt: Receipt?
    @Published var pending: Receipt?
    @Published var mergeSHA = ""
    @Published var appliedSHA = ""

    /// One compare request; nothing is written here.
    func loadPreview(api: GitHub, repo: String, branch: String) async {
        guard !loading else { return }
        let target: UpstreamSyncRules.Target
        do { target = try UpstreamSyncRules.target(repository: upstreamRepository, branch: upstreamBranch) }
        catch { compare = nil; self.error = error.localizedDescription; return }
        loading = true; error = ""; compare = nil
        defer { loading = false }
        do {
            let result = try await api.upstreamCompare(repo: repo, base: branch, upstream: target)
            try Task.checkCancellation()
            guard api.isCurrentSession else { return }
            compare = result
            upstreamRepository = target.repository
            upstreamBranch = target.branch
            stage = .preview; receipt = nil; pending = nil; mergeSHA = ""; appliedSHA = ""
            UserDefaults.standard.set(UpstreamSyncRules.encodeMemory(repository: target.repository, branch: target.branch),
                                      forKey: UpstreamSyncRules.memoryKey(account: api.accountID, repository: repo))
        } catch {
            guard api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
            self.error = Self.failureText(error)
        }
    }

    func propose(branch: String) -> Bool {
        guard let target = try? UpstreamSyncRules.target(repository: upstreamRepository, branch: upstreamBranch) else {
            error = "请先填写有效的上游仓库与分支，并预览差异。"; return false
        }
        let stamp = UpstreamSyncRules.stamp()
        pending = Receipt(stamp: stamp,
                          backupTag: UpstreamSyncRules.backupTag(stamp),
                          tempBranch: UpstreamSyncRules.tempBranch(stamp),
                          head: "", upstream: target.repository, upstreamBranch: target.branch)
        return true
    }

    func merge(api: GitHub, repo: String, branch: String, receipt proposed: Receipt) async {
        guard !busy else { return }
        guard let target = try? UpstreamSyncRules.target(repository: proposed.upstream, branch: proposed.upstreamBranch) else {
            error = "上游仓库或分支无效，未执行任何写入。"; return
        }
        busy = true; error = ""
        var current = proposed
        defer { busy = false }
        do {
            let head = try await api.upstreamBranchHead(repo: repo, branch: branch)
            guard api.isCurrentSession else { return }
            current.head = head
            receipt = current
            try await api.createUpstreamRef(repo: repo, ref: "refs/tags/" + current.backupTag, sha: head)
            guard api.isCurrentSession else { return }
            try await api.createUpstreamRef(repo: repo, ref: "refs/heads/" + current.tempBranch, sha: head)
            guard api.isCurrentSession else { return }
            let outcome = try await api.mergeUpstream(
                repo: repo, base: current.tempBranch, upstream: target,
                message: UpstreamSyncRules.mergeMessage(targetBranch: branch, upstream: target, stamp: current.stamp))
            guard api.isCurrentSession else { return }
            switch outcome {
            case .merged(let sha): mergeSHA = sha; stage = .merged
            case .upToDate: stage = .upToDate
            case .conflict: stage = .conflict
            case .rejected(let text): stage = .failed; error = text
            }
        } catch {
            stage = .failed
            guard api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
            self.error = Self.failureText(error)
        }
    }

    func apply(api: GitHub, repo: String, branch: String) async {
        guard !busy, stage == .merged, UpstreamSyncRules.validSHA(mergeSHA) else { return }
        busy = true; error = ""
        defer { busy = false }
        do {
            let outcome = try await api.applyUpstreamFastForward(repo: repo, branch: branch, sha: mergeSHA)
            guard api.isCurrentSession else { return }
            switch outcome {
            case .updated(let sha): appliedSHA = sha; stage = .applied
            case .rejected(let text): error = text
            }
        } catch {
            guard api.isCurrentSession, !RefreshFailure.isCancellation(error) else { return }
            self.error = Self.failureText(error)
        }
    }

    func restore(account: String, repo: String) {
        guard upstreamRepository.isEmpty, upstreamBranch.isEmpty else { return }
        let saved = UpstreamSyncRules.decodeMemory(
            UserDefaults.standard.string(forKey: UpstreamSyncRules.memoryKey(account: account, repository: repo)))
        guard let saved else { return }
        upstreamRepository = saved.repository
        upstreamBranch = saved.branch
    }

    static func failureText(_ error: Error) -> String {
        if let api = error as? GitHubAPIError,
           let text = UpstreamSyncRules.permissionFailure(status: api.status, operation: api.operation, reason: api.reason) {
            return text
        }
        let text = error.localizedDescription
        return text.contains("推送权限") ? text + "\n" + UpstreamSyncRules.permissionHelp : text
    }
}

struct UpstreamSyncView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    let canWrite: Bool
    let repository: Repository?
    @StateObject private var state = UpstreamSyncState()
    @State private var confirmingMerge = false
    @State private var confirmingApply = false

    private var targetBranch: String { branch.isEmpty ? "默认分支" : branch }
    private var commits: [UpstreamCompare.Commit] {
        Array((state.compare?.commits ?? []).prefix(UpstreamSyncRules.commitLimit))
    }
    private var files: [UpstreamCompare.File] {
        Array((state.compare?.files ?? []).prefix(UpstreamSyncRules.fileLimit))
    }
    private var hints: [(repository: String, branch: String?, title: String)] {
        UpstreamSyncRules.candidates(parent: repository?.parent?.full_name,
                                     source: repository?.source?.full_name,
                                     current: repo).map { name in
            let isParent = repository?.parent?.full_name.lowercased() == name.lowercased()
            let reference = isParent ? repository?.parent : repository?.source
            return (name, reference?.default_branch, isParent ? "父仓库" : "来源仓库")
        }
    }
    private var canMerge: Bool {
        canWrite && !state.busy && state.stage == .preview && (state.compare?.ahead_by ?? 0) > 0
    }
    private var mergeTitle: String {
        guard let pending = state.pending else { return "在临时分支合并上游？" }
        return "在临时分支合并上游？\n\(pending.backupTag)\n\(pending.tempBranch)\n"
            + "\(pending.upstream):\(pending.upstreamBranch) → \(pending.tempBranch)\n"
            + "目标分支 \(targetBranch) 不改变，冲突时停止。"
    }
    private func short(_ sha: String) -> String { String(sha.prefix(7)) }
    private func title(_ message: String) -> String {
        let first = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return String((trimmed.isEmpty ? "（无提交说明）" : trimmed).prefix(120))
    }

    var body: some View {
        List {
            sourceSection
            previewSection
            mergeSection
            resultSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("上游同步")
        .adaptiveWorkspaceLayout()
        .task { state.restore(account: api.accountID, repo: repo) }
        .confirmationDialog(mergeTitle, isPresented: $confirmingMerge, titleVisibility: .visible) {
            Button("确认合并到临时分支") {
                guard let pending = state.pending else { return }
                state.pending = nil
                Task { await state.merge(api: api, repo: repo, branch: branch, receipt: pending) }
            }
            Button("取消", role: .cancel) { state.pending = nil }
        }
        .confirmationDialog("将 \(targetBranch) 快进到 \(short(state.mergeSHA))？\n只接受快进，不会改写历史；被拒绝时目标分支与临时分支都会保留。",
                            isPresented: $confirmingApply, titleVisibility: .visible) {
            Button("应用快进更新") { Task { await state.apply(api: api, repo: repo, branch: branch) } }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder private var sourceSection: some View {
        Section {
            SoftGroupRows {
                SoftGroupRow("upstream-repository") {
                    TextField("上游仓库（owner/repo 或链接）", text: $state.upstreamRepository)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: state.upstreamRepository) { _ in state.compare = nil }
                }
                SoftGroupRow("upstream-branch") {
                    TextField("上游分支", text: $state.upstreamBranch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: state.upstreamBranch) { _ in state.compare = nil }
                }
                for hint in hints {
                    SoftGroupRow("candidate-" + hint.repository) {
                        Button {
                            state.upstreamRepository = hint.repository
                            if let branch = hint.branch, !branch.isEmpty { state.upstreamBranch = branch }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hint.repository)
                                Text(hint.branch.map { "\(hint.title) · 默认分支 \($0)" } ?? hint.title)
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                    }
                }
                if state.upstreamRepository.isEmpty && state.upstreamBranch.isEmpty {
                    SoftGroupRow("upstream-hint") {
                        Text("填写要比较的上游仓库与分支；不会自动选择任何项目。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SoftGroupRow("preview") {
                    Button(state.loading ? "正在比较…" : "预览差异（只读）") {
                        Task { await state.loadPreview(api: api, repo: repo, branch: branch) }
                    }
                    .disabled(state.loading || state.upstreamRepository.isEmpty || state.upstreamBranch.isEmpty)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                if !state.error.isEmpty && state.stage == .preview {
                    SoftGroupRow("preview-error") {
                        Text(state.error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("上游来源")
        } footer: {
            Text("预览只发出一次只读比较请求，不创建分支、标签或提交。选择按仓库分别记住，只有你确认过的选择会被保存。")
        }
    }

    @ViewBuilder private var previewSection: some View {
        if let compare = state.compare {
            Section("差异预览") {
                SoftGroupRows {
                    SoftGroupRow("summary") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(compare.status ?? "")
                            Text("上游新增 \(compare.ahead_by ?? 0) 个提交 · 目标分支多出 \(compare.behind_by ?? 0) 个提交")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if (compare.total_commits ?? 0) > commits.count {
                                Text("比较结果共 \(compare.total_commits ?? 0) 个提交，仅列出最近 \(commits.count) 个。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if commits.isEmpty {
                        SoftGroupRow("no-commits") {
                            Text("没有需要合并的上游提交。").foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(commits) { commit in
                    HStack(alignment: .top, spacing: 10) {
                        Text(short(commit.sha)).font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(commit.commit.message)).lineLimit(2)
                            Text((commit.commit.author?.name ?? "未知作者") + " · "
                                 + CommitDatePresentation.local(commit.commit.author?.date ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.softGroupedRow(top: commit.id == commits.first?.id,
                                     bottom: files.isEmpty && commit.id == commits.last?.id)
                }
                if !files.isEmpty {
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.filename).font(.callout)
                            Text("+\(file.additions ?? 0) / −\(file.deletions ?? 0)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.softGroupedRow(top: commits.isEmpty && file.id == files.first?.id,
                                         bottom: file.id == files.last?.id)
                    }
                    Text((compare.files?.count ?? 0) > files.count
                         ? "变更文件超过 \(UpstreamSyncRules.fileLimit) 个，仅显示前 \(UpstreamSyncRules.fileLimit) 个；GitHub 最多返回 3,000 个文件。"
                         : "文件统计由 GitHub 比较接口返回；二进制文件不会给出文本差异。")
                        .font(.caption).foregroundStyle(.secondary)
                        .softGroupedRow(top: false, bottom: true)
                }
            }
        }
    }

    @ViewBuilder private var mergeSection: some View {
        Section {
            SoftGroupRows {
                SoftGroupRow("merge") {
                    Button("创建备份标签与临时分支并合并") {
                        if state.propose(branch: branch) { confirmingMerge = true }
                    }
                    .disabled(!canMerge)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                if !canWrite {
                    SoftGroupRow("merge-permission") {
                        Text("此账号没有已确认的仓库推送权限：预览可用，合并与应用需要 Contents: write。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let compare = state.compare, (compare.ahead_by ?? 0) == 0 {
                    SoftGroupRow("merge-no-change") {
                        Text("上游没有新的提交，无需合并。").font(.caption).foregroundStyle(.secondary)
                    }
                } else if state.compare == nil {
                    SoftGroupRow("merge-needs-preview") {
                        Text("先预览差异，确认后才允许写入。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("合并到临时分支")
        } footer: {
            Text("读取 \(targetBranch) 的最新提交 → 创建备份标签 → 在相同提交创建临时分支 → 只把上游合并进临时分支。\(targetBranch) 在“应用”前不会改变；冲突时立即停止，没有 force 选项。")
        }
    }

    @ViewBuilder private var resultSection: some View {
        if state.stage != .preview || state.receipt != nil {
            Section("同步结果") {
                if state.busy { ProgressView("正在等待 GitHub…").softGroupedRow(top: true) }
                SoftGroupRows {
                    if let receipt = state.receipt {
                        SoftGroupRow("backup-tag") { LabeledContent("备份标签", value: receipt.backupTag) }
                        SoftGroupRow("temp-branch") { LabeledContent("临时分支", value: receipt.tempBranch) }
                        if !receipt.head.isEmpty {
                            SoftGroupRow("head") { LabeledContent("起点提交", value: short(receipt.head)) }
                        }
                    }
                    if state.stage == .merged {
                        SoftGroupRow("merge-done") { Text("合并成功，目标分支尚未改变。") }
                        SoftGroupRow("apply") {
                            Button("应用到目标分支") { confirmingApply = true }
                                .disabled(state.busy || !canWrite)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                    if state.stage == .upToDate {
                        SoftGroupRow("up-to-date") {
                            Text("上游没有可合并的新提交；已创建的备份标签与临时分支保留，目标分支未改变。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if state.stage == .conflict {
                        SoftGroupRow("conflict") {
                            Text("检测到冲突，已停止。未自动解决冲突，未选择任何一方，目标分支未改变。")
                                .font(.caption).foregroundStyle(.red)
                        }
                        SoftGroupRow("conflict-help") {
                            Text("临时分支与备份标签已保留，可在电脑上查看差异、解决冲突后自行处理。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !state.error.isEmpty {
                        SoftGroupRow("error") {
                            Text(state.error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    if state.stage == .applied {
                        SoftGroupRow("applied") {
                            Text("已应用：\(targetBranch) 现在指向 \(short(state.appliedSHA))。")
                        }
                    }
                }
            }
        }
    }
}
