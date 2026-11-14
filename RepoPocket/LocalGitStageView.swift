import SwiftUI

struct LocalGitStageView: View {
    @ObservedObject var api: GitHub
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let changed: () -> Void
    @Binding var message: String
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("localGit.authorName") private var authorName = ""
    @AppStorage("localGit.authorEmail") private var authorEmail = ""
    @State private var snapshot: LocalGitStageStatus?
    @State private var stagedSelection = Set<String>()
    @State private var unstagedSelection = Set<String>()
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var visible = false
    @State private var confirming = false
    @State private var error = ""
    @State private var result = ""
    private var sessionValid: Bool { project.active && generation == AccountStore.generation && api.isCurrentSession && isValid() }
    private var valid: Bool { visible && sessionValid }
    private var ready: Bool {
        valid && !busy && snapshot?.canCommit == true &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        List {
            Section {
              SoftGroupRows(bottom: snapshot == nil) {
                SoftGroupRow("explanation") {
                    Text("暂存只保存勾选文件的当前版本；取消暂存只还原 index，不改工作文件。提交包含全部已暂存内容，不包含之后的未暂存修改，不自动推送。改名按删除与新增分别选择。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SoftGroupRow("actions") { NativeActionMenu(title: "暂存操作", accessibilityIdentifier: "localgit.stage-actions", enabled: valid && !busy, items: menuItems) }
                if let snapshot {
                    SoftGroupRow("branch") { Text("分支：" + snapshot.branch + " · " + String(snapshot.head.prefix(7))).font(.caption) }
                    SoftGroupRow("pin") { Text("已确认 index：" + snapshot.indexFingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if busy {
                    SoftGroupRow("busy") { ProgressView("核对暂存区…") }
                    SoftGroupRow("cancel") { Button("取消等待") { task?.cancel(); snapshot = nil; result = "已取消等待；发布可能已完成，请刷新核对真实状态。" } }
                }
                if !error.isEmpty { SoftGroupRow("error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if !result.isEmpty { SoftGroupRow("result") { Text(result).textSelection(.enabled) } }
              }
              if let snapshot {
                fileSection(snapshot.staged, staged: true, snapshot: snapshot)
                fileSection(snapshot.unstaged, staged: false, snapshot: snapshot)
                SoftGroupRows(top: false) {
                    SoftGroupRow("commit-heading") { Text("提交全部已暂存内容").font(.subheadline).foregroundStyle(.secondary) }
                    SoftGroupRow("author") { TextField("作者姓名", text: $authorName).disabled(busy) }
                    SoftGroupRow("email") { TextField("作者邮箱", text: $authorEmail).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress).disabled(busy) }
                    SoftGroupRow("message") { TextField("提交说明", text: $message).disabled(busy) }
                    SoftGroupRow("commit") { Button("提交已确认的暂存内容…") { confirming = true }.disabled(!ready).accessibilityIdentifier("localgit.commit-staged") }
                }
              }
            }
        }.listStyle(.insetGrouped).navigationTitle("暂存与提交").adaptiveWorkspaceLayout()
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; task?.cancel(); confirming = false }
        .onChange(of: sessionValid) { active in if !active { task?.cancel(); confirming = false; snapshot = nil } }
        .onChange(of: scenePhase) { phase in
            if phase == .active, valid, !busy { refresh() }
            else if phase != .active { task?.cancel(); snapshot = nil; confirming = false }
        }
        .refreshable { await load() }
        .alert("提交全部已暂存内容？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("确认本地提交") { if ready { mutate("commitStaged") } }
        } message: {
            Text("账号：\(api.login)\n分支：\(snapshot?.branch ?? "")\n全部 \(snapshot?.staged.count ?? 0) 个已暂存文件（不受勾选影响）。\n不包含工作区后续改动；不会推送或运行工作流。")
        }
    }
    private var menuItems: [NativeMenuItem] {
        [NativeMenuItem(id: "stage", title: "暂存勾选文件（\(unstagedSelection.count)）", symbol: "plus.circle", enabled: !unstagedSelection.isEmpty && unstagedSelection.count <= 1000 && snapshot != nil, perform: { mutate("stage") }),
         NativeMenuItem(id: "unstage", title: "取消勾选暂存（\(stagedSelection.count)）", symbol: "minus.circle", enabled: !stagedSelection.isEmpty && stagedSelection.count <= 1000 && snapshot != nil, perform: { mutate("unstage") }),
         NativeMenuItem(id: "refresh", title: "重新核对", symbol: "arrow.clockwise", perform: refresh)]
    }
    private func fileSection(_ files: [LocalGitChange], staged: Bool, snapshot: LocalGitStageStatus) -> some View {
            SoftGroupRows(top: false, bottom: false) {
                SoftGroupRow("heading") { Text((staged ? "已暂存 · HEAD → index" : "未暂存 · index → 工作区") + "（\(files.count)）").font(.subheadline).foregroundStyle(.secondary) }
                if files.isEmpty { SoftGroupRow("empty") { Text("无变化").foregroundStyle(.secondary) } }
                for file in files {
                    SoftGroupRow("file:" + file.path) {
                        HStack {
                            Button { toggle(file.path, staged: staged) } label: {
                                Image(systemName: (staged ? stagedSelection : unstagedSelection).contains(file.path) ? "checkmark.circle.fill" : "circle")
                            }.buttonStyle(.borderless).disabled(busy || !valid || !file.blocked.isEmpty)
                                .accessibilityLabel((staged ? "选择取消暂存 " : "选择暂存 ") + file.path)
                            NavigationLink {
                                LocalGitStageDiffView(project: project, metadata: metadata, internalRoot: internalRoot, generation: generation,
                                    isValid: { sessionValid }, snapshot: snapshot, file: file, staged: staged)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.path)
                                    Text(file.blocked.isEmpty ? file.label : file.blocked).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(busy || !valid || !file.blocked.isEmpty)
                        }
                    }
                }
            }
    }
    private func toggle(_ path: String, staged: Bool) {
        if staged { if !stagedSelection.insert(path).inserted { stagedSelection.remove(path) } }
        else { if !unstagedSelection.insert(path).inserted { unstagedSelection.remove(path) } }
    }
    private func refresh() { guard valid, !busy else { return }; task = Task { await load() } }
    @MainActor private func load() async {
        guard valid, !busy else { return }; busy = true; error = ""; snapshot = nil
        stagedSelection.removeAll(); unstagedSelection.removeAll(); defer { busy = false }
        do {
            let value: LocalGitStageStatus = try await LocalGitEngine.shared.run("stageStatus", project: project, metadata: metadata, internalRoot: internalRoot, generation: generation)
            try Task.checkCancellation(); if valid { snapshot = value }
        } catch { if valid { self.error = error.localizedDescription } }
    }
    private func mutate(_ operation: String) {
        guard valid, !busy, let snapshot else { return }
        if operation == "commitStaged", !ready { return }
        let paths = operation == "unstage" ? stagedSelection : unstagedSelection
        if operation != "commitStaged", paths.isEmpty || paths.count > 1000 { return }
        var args = snapshot.arguments(selecting: paths, staged: operation == "unstage")
        if operation == "commitStaged" { args["message"] = message; args["authorName"] = authorName; args["authorEmail"] = authorEmail }
        busy = true; error = ""; result = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let reply: LocalGitReply = try await LocalGitEngine.shared.run(operation, project: project, metadata: metadata, internalRoot: internalRoot, arguments: args, generation: generation)
                changed() // Even if the account/page changed, invalidate the parent's cached result.
                try Task.checkCancellation(); guard valid else { return }
                result = operation == "commitStaged" ? "本地提交已保存：\(reply.commit ?? "")\n尚未推送。" : "暂存区已更新，工作文件未更改。"
                self.snapshot = nil; stagedSelection.removeAll(); unstagedSelection.removeAll()
                busy = false; await load()
            } catch {
                changed(); self.snapshot = nil; stagedSelection.removeAll(); unstagedSelection.removeAll()
                if valid { self.error = "\(error.localizedDescription)\n请重新核对真实状态；不会自动撤销或清理文件。" }
            }
        }
    }
}
