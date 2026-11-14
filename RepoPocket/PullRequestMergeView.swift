import SwiftUI

struct PullRequestMergeView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let number: Int
    @StateObject private var state = PullRequestMergeState()
    @State private var method = PullRequestMergeMethod.merge
    @State private var title = ""
    @State private var message = ""
    @State private var confirmation: PullRequestMergeConfirmation?
    @State private var validation = ""
    var body: some View {
        List {
            Section {
                SoftGroupRows { rows }
            }
        }.listStyle(.insetGrouped).navigationTitle("合并PR").adaptiveWorkspaceLayout()
        .toolbar { Button(state.pending == nil ? "刷新条件" : "只读核实") { state.load(api: api, repo: repo, number: number) }.disabled(state.busy) }
        .task { if state.options == nil && state.result.isEmpty { state.load(api: api, repo: repo, number: number) } }
        .onDisappear { state.cancel() }
        .onChange(of: state.options?.id) { _ in
            if let options = state.options, options.reason(method) != nil,
               let allowed = PullRequestMergeMethod.allCases.first(where: { options.reason($0) == nil }) { method = allowed }
        }
        .confirmationDialog("确认" + (confirmation?.method.title ?? "合并") + "？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible, presenting: confirmation) { target in
            Button("确认" + target.method.title) { state.apply(target, api: api); confirmation = nil }
            Button("取消", role: .cancel) { confirmation = nil }
        } message: { target in
            Text("\(target.repo) #\(number)\n\(target.options.pull.head.ref) → \(target.options.pull.base.ref)\n\(target.method.title)\n\(target.title.isEmpty ? "使用GitHub默认提交说明" : target.title)\n\(target.message)")
        }
    }
    @SoftGroupRowsBuilder private var rows: [SoftGroupRow] {
        SoftGroupRow("scope") { Text(repo + " #\(number)").font(.headline) }
        if let options = state.options { optionRows(options) }
        if state.busy { SoftGroupRow("progress") { ProgressView("检查或处理PR…") } }
        if !validation.isEmpty { SoftGroupRow("validation") { Text(validation).font(.caption).foregroundStyle(.red) } }
        if !state.error.isEmpty { SoftGroupRow("error") { Text(state.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) } }
        if !state.result.isEmpty { SoftGroupRow("result") { Text(state.result).textSelection(.enabled).accessibilityIdentifier("pr-merge-result") } }
        if state.pending != nil {
            SoftGroupRow("reconcile") { Button("只读核实合并结果") { state.load(api: api, repo: repo, number: number) }.disabled(state.busy) }
        }
    }
    @SoftGroupRowsBuilder private func optionRows(_ options: PullRequestMergeOptions) -> [SoftGroupRow] {
        SoftGroupRow("branches") {
            VStack(alignment: .leading, spacing: 5) {
                Text(options.pull.head.ref + " → " + options.pull.base.ref)
                Text("来源 \(options.pull.head.sha.prefix(8)) · 目标 \(options.pull.base.sha.prefix(8))").font(.caption).foregroundStyle(.secondary)
                Text("GitHub检查：" + options.gate.mergeStateStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        SoftGroupRow("method") {
            mergeMenu(options).frame(maxWidth: .infinity, alignment: .leading)
        }
        for value in PullRequestMergeMethod.allCases {
            if let reason = options.reason(value) {
                SoftGroupRow("reason-" + value.rawValue) { Text(value.title + "：" + reason).font(.caption).foregroundStyle(.secondary) }
            }
        }
        if method != .rebase {
            SoftGroupRow("title") { TextField("提交标题（留空使用GitHub默认）", text: $title).disabled(state.busy || state.pending != nil) }
            SoftGroupRow("message") { TextField("提交说明（留空使用GitHub默认）", text: $message).disabled(state.busy || state.pending != nil) }
        }
        SoftGroupRow("preview") {
            Button("预览并确认" + method.title) { prepare(options) }
                .disabled(state.busy || state.pending != nil || options.reason(method) != nil || !api.isCurrentSession)
                .accessibilityIdentifier("pr-merge-preview")
        }
    }
    private func mergeMenu(_ options: PullRequestMergeOptions) -> NativeActionMenu {
        let children: [NativeMenuItem] = PullRequestMergeMethod.allCases.map { value in
            NativeMenuItem(id: value.rawValue, title: value.title, enabled: options.reason(value) == nil,
                selected: method == value, hint: options.reason(value)) { method = value }
        }
        return NativeActionMenu(title: "合并方式：" + method.title, symbol: nil, accessibilityIdentifier: "pr-merge-method", enabled: !state.busy && state.pending == nil,
            items: [.submenu("合并方式", symbol: "arrow.triangle.merge", singleSelection: true, children: children)])
    }
    private func prepare(_ options: PullRequestMergeOptions) {
        do {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty { _ = try RemoteBranchMergeRules.title(cleanTitle) }
            guard message.utf8.count <= 60_000 else { throw AppError(text: "提交说明不能超过60 KB。") }
            confirmation = .init(accountID: api.accountID, generation: AccountStore.generation, repo: repo, options: options, method: method, title: cleanTitle, message: message)
            validation = ""
        } catch { validation = error.localizedDescription }
    }
}
