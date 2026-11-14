import SwiftUI

struct LocalGitConflictEditor: View {
    let project: LocalGitProject
    let metadata: URL
    let internalRoot: URL
    let generation: UUID
    let isValid: () -> Bool
    let session: LocalGitConflictSession
    let path: String
    let changed: () -> Void
    @State private var file: LocalGitConflictFile?
    @State private var text = ""
    @State private var original = ""
    @State private var tab = "result"
    @State private var busy = false
    @State private var error = ""
    @State private var note = ""
    @State private var choice = "manual"
    @State private var confirming = false
    @State private var discard = false
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool { project.active && generation == AccountStore.generation && isValid() }
    private var blocks: [LocalGitConflictBlocks.Block] { LocalGitConflictBlocks.parse(text) }
    private var editorText: Binding<String> {
        Binding(get: { tab == "result" ? text : (tab == "ours" ? file?.ours.text ?? "" : file?.theirs.text ?? "") },
                set: { if tab == "result" { text = $0 } })
    }
    private var side: LocalGitConflictFile.Side? { tab == "ours" ? file?.ours : (tab == "theirs" ? file?.theirs : nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前：\(session.targetName) · 传入：\(session.sourceName)").font(.caption).padding(.horizontal)
            Picker("比较视图", selection: $tab) {
                Text("结果").tag("result"); Text("当前分支").tag("ours"); Text("传入分支").tag("theirs")
            }.pickerStyle(.segmented).padding(.horizontal)
            if let file {
                if file.binary {
                    List {
                        Section("二进制或非 UTF-8 · 明确选择整份文件") {
                            Text("不把二进制转换成文本，不拼接双方内容。请选择当前或传入一方；该方不存在即表示删除。")
                            Text("当前 \(file.ours.exists ? file.ours.oid : "已删除")").font(.caption.monospaced())
                            Text("传入 \(file.theirs.exists ? file.theirs.oid : "已删除")").font(.caption.monospaced())
                            Text("结果 \(file.resolved ? (file.resultExists ? file.resultOID : "已标记删除") : "尚未标记解决")").font(.caption.monospaced())
                        }
                    }
                } else if let side, !side.exists {
                    Text("此分支已删除该文件。").foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    if tab == "result", !blocks.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(Array(blocks.enumerated()), id: \.element.id) { number, block in
                                    NativeActionMenu(title: "冲突块 \(number + 1)", symbol: nil, enabled: !busy && valid, items: [
                                        NativeMenuItem(id: "ours", title: "采用当前分支", perform: { apply(block, "ours") }),
                                        NativeMenuItem(id: "theirs", title: "采用传入分支", perform: { apply(block, "theirs") }),
                                        NativeMenuItem(id: "both", title: "采用双方（当前在前）", perform: { apply(block, "both") })
                                    ])
                                }
                            }.padding(.horizontal)
                        }
                    }
                    SourceCodeEditor(text: editorText, filename: path, readOnly: tab != "result" || !valid).disabled(busy)
                }
                HStack {
                    NativeActionMenu(title: "文件解决方式", enabled: !busy && valid, items: [
                        NativeMenuItem(id: "ours", title: file.ours.exists ? "整份采用当前分支" : "采用当前分支（删除）", perform: { ask("ours") }),
                        NativeMenuItem(id: "theirs", title: file.theirs.exists ? "整份采用传入分支" : "采用传入分支（删除）", perform: { ask("theirs") }),
                        NativeMenuItem(id: "delete", title: "删除结果文件", destructive: true, perform: { ask("delete") })
                    ])
                    Spacer()
                    if !file.binary {
                        Button("标记当前结果已解决…") { ask("manual") }
                            .disabled(busy || !valid || !blocks.isEmpty || tab != "result")
                    }
                }.padding(.horizontal)
            }
            if busy { ProgressView("正在核对冲突文件…").padding(.horizontal) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
        }.navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(text != original)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if text != original { Button("返回") { discard = true }.disabled(busy) }
            }
        }
        .task { await load() }
        .onDisappear { task?.cancel() }
        .onChange(of: valid) { active in if !active { task?.cancel(); confirming = false } }
        .alert("确认此文件的解决结果？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("标记已解决") { task = Task { await resolve() } }
        } message: { Text(path + "\n" + (choice == "manual" ? "保存编辑后的结果" : (choice == "ours" ? "采用当前分支（不存在则删除）" : (choice == "theirs" ? "采用传入分支（不存在则删除）" : "删除结果文件"))) + "。仅更新本地合并暂存区，不直接修改工作文件。") }
        .confirmationDialog("未标记的编辑尚未保存", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃此页编辑并返回", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
    private func ask(_ value: String) { guard valid, !busy else { return }; choice = value; confirming = true }
    private func apply(_ block: LocalGitConflictBlocks.Block, _ value: String) {
        guard valid, !busy, blocks.contains(where: { $0.id == block.id && $0.range == block.range }) else { return }
        text = LocalGitConflictBlocks.applying(block, choice: value, to: text)
    }
    private func load() async {
        guard valid, !busy else { return }; busy = true; error = ""; defer { busy = false }
        do {
            var args = session.arguments; args["path"] = path
            let value: LocalGitConflictFile = try await LocalGitEngine.shared.run("conflictFile", project: project, metadata: metadata, internalRoot: internalRoot, arguments: args, generation: generation)
            try Task.checkCancellation(); guard valid else { return }
            file = value; text = value.result; original = text
            note = value.resolved ? (value.resultExists ? "此文件已标记解决；可重新选择或编辑结果。" : "已标记删除。") : "逐块采用一方/双方，或直接编辑结果后标记已解决。"
        } catch { if valid, !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
    }
    private func resolve() async {
        guard valid, !busy, let file else { return }; busy = true; error = ""; defer { busy = false }
        do {
            var args = session.arguments; args["indexFingerprint"] = file.indexFingerprint
            args["path"] = path; args["choice"] = choice; args["text"] = text
            let _: LocalGitConflictSession = try await LocalGitEngine.shared.run("conflictResolve", project: project, metadata: metadata, internalRoot: internalRoot, arguments: args, generation: generation)
            try Task.checkCancellation(); guard valid else { return }; original = text; changed(); dismiss()
        } catch { if valid { self.error = RefreshFailure.isCancellation(error) ? "已取消，请返回重新核对解决进度。" : error.localizedDescription } }
    }
}
