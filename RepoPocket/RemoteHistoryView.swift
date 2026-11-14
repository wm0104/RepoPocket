import SwiftUI

struct RemoteHistoryView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    @StateObject private var state = RemoteHistoryState()
    @State private var selected: Set<String> = []
    @State private var message = RemoteHistoryRules.snapshotMessage
    @State private var preview: RemoteHistoryPreview?
    @State private var confirmation: RemoteHistoryPreview?
    @State private var previewError = ""
    @State private var versionMode = false
    @State private var versions: [RemoteHistoryVersion] = []
    @State private var baseline: String?
    @State private var snapshotTarget: UUID?
    @State private var exporting = false
    @State private var sharedBackup: SharedFile?
    @State private var exportedBackupURL: URL?

    var body: some View {
        content.listStyle(.insetGrouped).navigationTitle("整理提交历史").adaptiveWorkspaceLayout()
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            NativeActionMenu(title: "历史整理操作", enabled: !state.busy && state.pendingHead == nil, items: [
                .submenu("整理方式", symbol: "list.bullet", singleSelection: true, children: [
                    NativeMenuItem(id: "versions", title: "按版本整理", symbol: "tag", selected: versionMode) { versionMode = true; preview = nil },
                    NativeMenuItem(id: "selection", title: "多选清除 / 压缩成一条", symbol: "list.bullet", selected: !versionMode) { versionMode = false; preview = nil }
                ]),
                NativeMenuItem(id: "refresh", title: "重新读取当前分支", symbol: "arrow.clockwise", perform: reload)
            ])
          }
          ToolbarItemGroup(placement: .keyboard) {
              Spacer()
              Button("完成输入") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
          }
        }
        .task { if state.pendingHead != nil { state.checkResult(api: api) } else if state.snapshot == nil && state.result.isEmpty { reload() } }
        .onDisappear { state.cancel() }
        .onChange(of: selected) { _ in preview = nil; previewError = "" }
        .onChange(of: message) { _ in preview = nil; previewError = "" }
        .onChange(of: versions) { _ in preview = nil; previewError = ""; confirmation = nil }
        .onChange(of: baseline) { _ in preview = nil; previewError = ""; confirmation = nil }
        .sheet(item: $sharedBackup, onDismiss: {
            if let file = exportedBackupURL { try? FileManager.default.removeItem(at: file) }
            exportedBackupURL = nil
        }) { ShareSheet(url: $0.url) }
        .confirmationDialog("整理已推送的当前分支历史？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible, presenting: confirmation) { target in
            Button("确认整理", role: .destructive) { preview = nil; state.apply(target, api: api); confirmation = nil }
            Button("取消", role: .cancel) { confirmation = nil }
        } message: { target in
            Text("\(target.snapshot.repository)\n\(target.snapshot.branch) · \(target.selected.count)条\n先保留本机原历史备份，保留每版确认的完整代码。仅在远端HEAD仍与预览一致时更新，不自动修改保护设置、其他分支或标签。移除账号会清理对应本机备份，可先导出。")
        }
    }
    private var content: some View {
        List {
            Section {
                SoftGroupRows { statusRows }
                if let snapshot = state.snapshot {
                    if versionMode { versionEditor(snapshot) }
                    SoftGroupRows(spacingBefore: 10) { selectionRows(snapshot) }
                    SoftGroupRows(spacingBefore: 10) { actionRows(snapshot) }
                }
                if let preview { SoftGroupRows(spacingBefore: 10) { previewRows(preview) } }
            }
        }
    }
    @SoftGroupRowsBuilder private var statusRows: [SoftGroupRow] {
        SoftGroupRow("scope") {
            VStack(alignment: .leading, spacing: 5) {
                Text(repo).font(.headline)
                Text("当前分支：" + (state.snapshot?.branch ?? branch)).font(.subheadline)
                Text("全部文件保持不变；只整理当前分支历史，其他分支和标签不变。").font(.caption).foregroundStyle(.secondary)
            }
        }
        if state.busy { SoftGroupRow("progress") { ProgressView(state.progress) } }
        if !state.error.isEmpty { SoftGroupRow("error") { Text(state.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) } }
        if !state.result.isEmpty { SoftGroupRow("result") { Text(state.result).font(.caption).textSelection(.enabled).accessibilityIdentifier("history-cleanup-result") } }
        if state.backupURL != nil {
            SoftGroupRow("backup") { Button(exporting ? "正在导出原历史备份…" : "导出原历史备份") { exportBackup() }.disabled(state.busy || exporting) }
        }
        if state.pendingHead != nil {
            SoftGroupRow("reconcile") { Button("只读核实更新结果") { state.checkResult(api: api) }.disabled(state.busy) }
        } else if state.snapshot == nil && !state.busy {
            SoftGroupRow("reload") { Button("读取当前分支历史") { reload() } }
        }
    }
    @SoftGroupRowsBuilder private func selectionRows(_ snapshot: RemoteHistorySnapshot) -> [SoftGroupRow] {
        SoftGroupRow("selection") {
          if versionMode {
            Text(snapshotTarget == nil ? "点选下方提交作为保留基线；该提交及更早祖先不变。" : "点选下方提交作为所选版本的最终快照。")
                .font(.caption).foregroundStyle(.secondary)
          } else {
            HStack {
                Button(selected.count == snapshot.commits.count ? "取消全选" : "全选当前分支（\(snapshot.commits.count)条）") {
                    selected = selected.count == snapshot.commits.count ? [] : Set(snapshot.commits.map(\.sha))
                }.accessibilityIdentifier("history-cleanup-select-all")
                Spacer()
                Text("已选 \(selected.count)").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.borderless).disabled(state.busy || state.pendingHead != nil)
          }
        }
        for commit in snapshot.commits {
            SoftGroupRow(commit.sha) {
                Button {
                    if versionMode {
                        if let target = snapshotTarget, let index = versions.firstIndex(where: { $0.id == target }) {
                            versions[index].finalCommit = commit.sha
                        } else { baseline = commit.sha }
                    } else if !selected.insert(commit.sha).inserted { selected.remove(commit.sha) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isChosen(commit.sha) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.commit.message.components(separatedBy: "\n").first ?? commit.sha).lineLimit(2)
                            Text(String(commit.sha.prefix(8)) + " · " + commit.commit.author.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(state.busy || state.pendingHead != nil)
                    .accessibilityValue(isChosen(commit.sha) ? "已选中" : "未选中")
                    .accessibilityIdentifier("history-cleanup-" + commit.sha)
            }
        }
    }
    @SoftGroupRowsBuilder private func actionRows(_ snapshot: RemoteHistorySnapshot) -> [SoftGroupRow] {
      if versionMode {
        SoftGroupRow("version-preview") {
            Button("预览按版本整理") { makeVersionPreview(snapshot) }
                .disabled(versions.isEmpty || state.busy || state.pendingHead != nil)
                .accessibilityIdentifier("history-version-preview")
        }
      } else {
        SoftGroupRow("message") {
            VStack(alignment: .leading, spacing: 5) {
                Text("新提交说明（压缩或生成当前快照时使用）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $message).frame(minHeight: 70).accessibilityIdentifier("history-cleanup-message")
            }.disabled(state.busy || state.pendingHead != nil)
        }
        SoftGroupRow("clear") { Button("预览清除选中记录", role: .destructive) { makePreview(.clear, snapshot: snapshot) }.disabled(selected.isEmpty || state.busy || state.pendingHead != nil) }
        SoftGroupRow("squash") { Button("预览压缩成一条") { makePreview(.squash, snapshot: snapshot) }.disabled(selected.isEmpty || state.busy || state.pendingHead != nil) }
      }
        if !previewError.isEmpty { SoftGroupRow("preview-error") { Text(previewError).font(.caption).foregroundStyle(.red) } }
    }
    @SoftGroupRowsBuilder private func previewRows(_ preview: RemoteHistoryPreview) -> [SoftGroupRow] {
        SoftGroupRow("preview") {
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.action == .versions ? "按版本整理预览" : (preview.action == .clear ? "清除选中记录预览" : "压缩成一条预览")).font(.headline)
                Text("\(preview.snapshot.branch) · 原HEAD \(preview.snapshot.head.prefix(8))")
                Text("选中 \(preview.selected.count) 条，准备 \(preview.recreatedCount) 个新提交对象。")
                if preview.resultKey == "current-snapshot" { Text("最后保留一条当前代码快照，全部文件保持不变。") }
                if preview.action == .versions {
                    Text("保留基线：" + (preview.baseline ?? "无，从根提交开始"))
                    Text("每版各生成一条提交，不修改版本文件。最后一版使用当前HEAD快照。")
                } else { Text("未选记录保留；重写的后续提交产生新SHA，原签名不会沿用。") }
                Text("执行前备份原历史，逐条核对代码树、说明和父子关系。新提交产生新SHA，原签名不沿用；其他引用仍可能保留旧提交。")
                Text("最终代码树：" + String(preview.snapshot.tree.prefix(12))).font(.system(.caption, design: .monospaced))
            }.font(.caption).textSelection(.enabled)
        }
        for version in preview.versions {
            SoftGroupRow("version-preview-" + version.id.uuidString) {
                VStack(alignment: .leading, spacing: 6) {
                    let index = preview.versions.firstIndex(where: { $0.id == version.id }) ?? 0
                    let start = index > 0 ? preview.versions[index - 1].finalCommit : (preview.baseline ?? "根提交之前")
                    Text(version.version).font(.headline)
                    Text(version.notes).font(.subheadline)
                    Text("原范围：" + start + "之后 → " + version.finalCommit).font(.caption).foregroundStyle(.secondary)
                    if let step = preview.steps.first(where: { $0.key == "version-" + version.id.uuidString }) {
                        Text("完整代码树：" + step.tree).font(.caption).foregroundStyle(.secondary)
                    }
                }.textSelection(.enabled)
            }
        }
        SoftGroupRow("confirm") {
            Button("确认整理当前分支历史", role: .destructive) { confirmation = preview }
                .disabled(state.busy || state.pendingHead != nil || !api.isCurrentSession)
                .accessibilityIdentifier("history-cleanup-confirm")
        }
    }
    private func reload() { selected = []; versions = []; baseline = nil; snapshotTarget = nil; preview = nil; confirmation = nil; previewError = ""; state.load(api: api, repo: repo, branch: branch) }
    private func makePreview(_ action: RemoteHistoryAction, snapshot: RemoteHistorySnapshot) {
        do { preview = try RemoteHistoryRules.preview(snapshot, selected: selected, action: action, message: message); previewError = "" }
        catch { preview = nil; previewError = error.localizedDescription }
    }
    private func isChosen(_ sha: String) -> Bool {
        guard versionMode else { return selected.contains(sha) }
        if let target = snapshotTarget { return versions.first { $0.id == target }?.finalCommit == sha }
        return baseline == sha
    }
    private func makeVersionPreview(_ snapshot: RemoteHistorySnapshot) {
        do {
            guard let baseline else { throw AppError(text: "请先明确保留基线，或明确选择从根提交开始。") }
            preview = try RemoteHistoryRules.versionPreview(snapshot, baseline: baseline.isEmpty ? nil : baseline, versions: versions)
            previewError = ""
        } catch { preview = nil; previewError = error.localizedDescription }
    }
    private func versionEditor(_ snapshot: RemoteHistorySnapshot) -> some View {
        Group {
            SoftGroupRows(spacingBefore: 10) {
                SoftGroupRow("version-help") {
                    Text("按旧到新填写每个版本，只写最终保留的功能和关键修复。版本范围由你确认，不按CI红绿筛选。最终快照仍有不要的功能时，请先移除代码，再整理历史。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SoftGroupRow("baseline") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("保留基线")
                            Text(baseline.map { $0.isEmpty ? "从根提交开始，不保留更早记录" : String($0.prefix(8)) + "及更早祖先保持不变" } ?? "尚未选择")
                                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("history-version-baseline")
                        }
                        Spacer()
                        NativeActionMenu(title: "选择保留基线", items: [
                            NativeMenuItem(id: "select", title: "在下方历史中选择", symbol: "list.bullet") { snapshotTarget = nil },
                            NativeMenuItem(id: "root", title: "从根提交开始", symbol: "arrow.up.to.line", destructive: true) { baseline = ""; snapshotTarget = nil }
                        ]).frame(width: 44, height: 44)
                    }
                }
            }
            ForEach($versions) { $version in
                SoftGroupRows(spacingBefore: 10) {
                    SoftGroupRow("version-title-" + version.id.uuidString) {
                        HStack {
                            TextField("版本号，例如1.2.0", text: $version.version).disableAutocorrection(true).textInputAutocapitalization(.never)
                                .accessibilityLabel("第\((versions.firstIndex { $0.id == version.id } ?? 0) + 1)版版本号")
                                .accessibilityIdentifier("history-version-title-" + version.id.uuidString)
                            NativeActionMenu(title: "版本操作", items: [
                                NativeMenuItem(id: "remove", title: "移除此版本分组", symbol: "trash", destructive: true) {
                                    versions.removeAll { $0.id == version.id }; if snapshotTarget == version.id { snapshotTarget = nil }
                                }
                            ]).frame(width: 44, height: 44)
                        }
                    }
                    SoftGroupRow("version-snapshot-" + version.id.uuidString) {
                        Button { snapshotTarget = version.id } label: {
                            HStack { Text("选择最终快照"); Spacer(); Text(version.finalCommit.isEmpty ? "未选择" : String(version.finalCommit.prefix(8))).foregroundStyle(.secondary) }
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.borderless).accessibilityLabel("第\((versions.firstIndex { $0.id == version.id } ?? 0) + 1)版选择最终快照")
                            .accessibilityIdentifier("history-version-snapshot-" + version.id.uuidString)
                    }
                    SoftGroupRow("version-notes-" + version.id.uuidString) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("该版本最终保留的功能和修复（作为提交正文）").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $version.notes).frame(minHeight: 90)
                                .accessibilityLabel("第\((versions.firstIndex { $0.id == version.id } ?? 0) + 1)版更新要点")
                                .accessibilityIdentifier("history-version-notes-" + version.id.uuidString)
                        }
                    }
                }
            }
            SoftGroupRows(spacingBefore: 10) {
                SoftGroupRow("add-version") {
                    Button("添加版本分组") { versions.append(RemoteHistoryVersion(finalCommit: snapshot.head)) }
                        .disabled(versions.count >= 100).accessibilityIdentifier("history-version-add")
                }
            }
        }.disabled(state.busy || state.pendingHead != nil)
    }
    private func exportBackup() {
        guard let folder = state.backupURL, !state.busy, !exporting else { return }
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                let file = try await RemoteHistoryBackup.archive(folder, api: api)
                exportedBackupURL = file; sharedBackup = SharedFile(url: file)
            } catch { if !RefreshFailure.isCancellation(error) { previewError = error.localizedDescription } }
        }
    }
}
