import SwiftUI

struct LocalProjectFile: Identifiable { let path: String; var deleting = false; var id: String { path } }
struct LocalProjectEditor: View {
    let project: LocalGitProject
    let internalRoot: URL
    let path: String
    var deleting = false
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fingerprint = ""
    @State private var error = ""
    @State private var busy = false
    @State private var attempted = false
    @State private var generation = AccountStore.generation
    @State private var task: Task<Void, Never>?
    @State private var editing = false
    @State private var originalText = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if deleting {
                    Form { Section {
                        Text(path).font(.caption).softGroupedRow(top: true)
                        Text("只删除这个文件。远端不会立即变化，之后仍需勾选删除记录并提交、推送。").softGroupedRow()
                        Button("确认删除此文件", role: .destructive) { save() }.disabled(busy || fingerprint.isEmpty).softGroupedRow(bottom: true)
                    } }
                } else if !fingerprint.isEmpty {
                    SourceCodeEditor(text: $text, filename: path, readOnly: !editing).disabled(busy)
                }
                if busy { ProgressView() }
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
                if fingerprint.isEmpty && !busy && !error.isEmpty { Button("重试读取") { Task { await open() } } }
            }.navigationTitle(deleting ? "删除文件" : (path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if !deleting { ToolbarItem(placement: .confirmationAction) {
                    Button(editing ? "保存" : "编辑") { if editing { save() } else { editing = true } }
                        .disabled(busy || fingerprint.isEmpty || (editing && text == originalText))
                } }
            }
            .task { guard !attempted else { return }; attempted = true; await open() }
            .onDisappear { task?.cancel() }
        }
    }
    private func open() async {
        busy = true; defer { busy = false }
        do {
            if deleting {
                fingerprint = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    try LocalGitFileAccess.fileFingerprint(root: root, path: path)
                }
            } else {
                let document = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    try LocalGitFileAccess.read(root: root, path: path)
                }
                text = document.text; originalText = document.text; fingerprint = document.fingerprint
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        guard !busy else { return }; busy = true; error = ""
        let value = text, expected = fingerprint
        task = Task { @MainActor in
            defer { busy = false }
            do {
                try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    guard generation == AccountStore.generation else { throw CancellationError() }
                    if deleting { try LocalGitFileAccess.delete(root: root, path: path, expected: expected) }
                    else { try LocalGitFileAccess.write(root: root, path: path, text: value, expected: expected) }
                }
                changed(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct LocalFileEntry: Identifiable { let path: String; let name: String; let directory: Bool; let size: Int64?; var id: String { path } }
struct LocalProjectFilesView: View {
    @ObservedObject var api: GitHub
    let project: LocalGitProject
    let internalRoot: URL
    var directory = ""
    let changed: () -> Void
    @StateObject private var importer = LocalGitImportState()
    @State private var generation = AccountStore.generation
    @State private var entries: [LocalFileEntry] = []
    @State private var opened: LocalProjectFile?
    @State private var loaded = false
    @State private var error = ""
    var body: some View {
        List {
          SoftGroupRows {
            SoftGroupRow("import-files") { Button("导入文件") { importer.picker = WorkspaceImportRequest(kind: .files) }.disabled(importer.busy) }
            SoftGroupRow("import-folder") { Button("导入文件夹") { importer.picker = WorkspaceImportRequest(kind: .folder) }.disabled(importer.busy) }
            if importer.busy { SoftGroupRow("import-busy") { ProgressView("导入中…") } }
            if !importer.message.isEmpty { SoftGroupRow("import-message") { Text(importer.message).font(.caption).foregroundStyle(.secondary) } }
            for entry in entries {
              SoftGroupRow("entry:" + entry.id) {
                if entry.directory {
                    NavigationLink { AnyView(LocalProjectFilesView(api: api, project: project, internalRoot: internalRoot, directory: entry.path, changed: changed)) } label: { Label(entry.name, systemImage: "folder") }
                } else {
                    HStack {
                        Button { opened = LocalProjectFile(path: entry.path) } label: { LocalGitFileLabel(name: entry.name, size: entry.size) }
                            .buttonStyle(.borderless)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        if entry.name.lowercased().hasSuffix(".deb") {
                            Menu { Button("编辑包信息") { opened = LocalProjectFile(path: entry.path) } }
                                label: { Image(systemName: "ellipsis").padding(8) }.accessibilityLabel("更多操作：" + entry.name)
                        }
                    }
                        .contextMenu { Button("删除此文件", role: .destructive) { opened = LocalProjectFile(path: entry.path, deleting: true) } }
                }
              }
            }
            if loaded && entries.isEmpty && error.isEmpty { SoftGroupRow("empty") { Text("文件夹为空") } }
            if !error.isEmpty { SoftGroupRow("failure") { Text(error).font(.caption).foregroundStyle(.red) } }
          }
        }.listStyle(.insetGrouped).navigationTitle(directory.isEmpty ? "项目文件" : (directory as NSString).lastPathComponent).adaptiveWorkspaceLayout()
        .task { guard !loaded else { return }; await load() }
        .toolbar { Button("刷新列表") { Task { await load() } }.disabled(importer.busy) }
        .refreshable { guard !importer.busy else { return }; await load() }
        .modifier(LocalGitImportPresentation(importer: importer, project: project, internalRoot: internalRoot,
                                              directory: directory, generation: generation) { _ in
            changed(); Task { await load() }
        })
        .onDisappear { importer.cancel() }
        .sheet(item: $opened, onDismiss: { Task { await load() } }) { file in
            if !file.deleting && file.path.lowercased().hasSuffix(".deb") {
                LocalProjectDebEditor(api: api, project: project, internalRoot: internalRoot, path: file.path, changed: changed)
            } else {
                LocalProjectEditor(project: project, internalRoot: internalRoot, path: file.path, deleting: file.deleting, changed: changed)
            }
        }
    }
    private func load() async {
        loaded = true; error = ""
        do {
            entries = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot) { root in
                let url = directory.isEmpty ? root : try LocalGitFileAccess.path(root: root, relative: directory)
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                guard children.count <= 2000 else { throw LocalGitError(text: "单个目录超过 2000 项，请使用桌面工具。") }
                return try children.filter { $0.lastPathComponent.lowercased() != ".git" }.compactMap { child in
                    let info = try child.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                    guard info.isSymbolicLink != true else { return nil }
                    let size = try FileManager.default.attributesOfItem(atPath: child.path)[.size] as? NSNumber
                    return LocalFileEntry(path: (directory.isEmpty ? "" : directory + "/") + child.lastPathComponent, name: child.lastPathComponent, directory: info.isDirectory == true, size: size?.int64Value)
                }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        } catch { self.error = error.localizedDescription }
    }
}
