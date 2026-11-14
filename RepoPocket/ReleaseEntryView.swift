import SwiftUI

// One form for Browser, local workspaces and the submit/publish tab. Repository
// creation is explicit, never deleted on failure, and reused when continuing.
struct ReleaseEntryView: View {
    @ObservedObject var api: GitHub
    @Environment(\.dismiss) private var dismiss
    @State private var repo: String
    @State private var makeNew = false
    @State private var name = ""
    @State private var isPrivate = true
    @State private var busy = false
    @State private var error = ""
    @State private var target: ReleaseEntryTarget?
    private let generation = AccountStore.generation
    init(api: GitHub, initialRepo: String = "") { self.api = api; _repo = State(initialValue: initialRepo) }
    var body: some View {
        NavigationStack {
            Form {
                Toggle("新建仓库后发布", isOn: $makeNew)
                if makeNew {
                    TextField("新仓库名称", text: $name).textInputAutocapitalization(.never)
                    Toggle("私有仓库", isOn: $isPrivate)
                    if !isPrivate { Text("公开仓库及正式发行版可被任何人访问。请确认不含敏感文件。").foregroundColor(.orange) }
                } else { TextField("仓库链接 / owner/repo", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled() }
                Button("检查权限并继续") { Task { await proceed() } }.disabled(busy || !api.isCurrentSession)
                Text("仅发布所选附件，不自动编译、打包或提交工作区；标签目标是明确选择的远端分支 / 提交。").font(.caption)
                if busy { ProgressView() }
                if !error.isEmpty { Text(error).foregroundColor(.red) }
            }.navigationTitle("发布为发行版")
                .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
                .interactiveDismissDisabled(busy)
                .sheet(item: $target) { value in ReleaseEditorView(api: api, repo: value.repo, original: nil) }
        }
    }
    private func proceed() async {
        guard !busy, generation == AccountStore.generation, api.isCurrentSession else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            if makeNew {
                let created = try await api.createRepository(name: name, isPrivate: isPrivate)
                guard generation == AccountStore.generation, api.isCurrentSession else { throw CancellationError() }
                repo = created.full_name; makeNew = false
            }
            let canonical = try RepositoryInput.parse(repo)
            try await api.requireWriteAccess(canonical)
            guard generation == AccountStore.generation, api.isCurrentSession else { throw CancellationError() }
            target = ReleaseEntryTarget(repo: canonical)
        } catch { if generation == AccountStore.generation, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
}
private struct ReleaseEntryTarget: Identifiable { let id = UUID(); let repo: String }
