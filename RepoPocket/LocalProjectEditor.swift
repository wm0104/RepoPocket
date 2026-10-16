import SwiftUI

struct LocalProjectFile: Identifiable { let path: String; var id: String { path } }
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

private struct LocalFileEntry: Identifiable { let path: String; let name: String; let directory: Bool; var id: String { path } }
struct LocalProjectFilesView: View {
    let project: LocalGitProject
    let internalRoot: URL
    var directory = ""
    let changed: () -> Void
    @State private var entries: [LocalFileEntry] = []
    @State private var opened: LocalProjectFile?
    @State private var deleting = false
    @State private var loaded = false
    @State private var error = ""
    var body: some View {
        List {
          SoftGroupRows {
            for entry in entries {
              SoftGroupRow(entry.id) {
                if entry.directory {
                    NavigationLink { AnyView(LocalProjectFilesView(project: project, internalRoot: internalRoot, directory: entry.path, changed: changed)) } label: { Label(entry.name, systemImage: "folder") }
                } else {
                    Button { deleting = false; opened = LocalProjectFile(path: entry.path) } label: { Label(entry.name, systemImage: "doc.text") }
                        .contextMenu { Button("删除此文件", role: .destructive) { deleting = true; opened = LocalProjectFile(path: entry.path) } }
                }
              }
            }
            if loaded && entries.isEmpty && error.isEmpty { SoftGroupRow("empty") { Text("文件夹为空") } }
            if !error.isEmpty { SoftGroupRow("failure") { Text(error).font(.caption).foregroundStyle(.red) } }
          }
        }.listStyle(.insetGrouped).navigationTitle(directory.isEmpty ? "项目文件" : (directory as NSString).lastPathComponent).adaptiveWorkspaceLayout()
        .task { guard !loaded else { return }; await load() }
        .toolbar { Button("刷新列表") { Task { await load() } } }
        .refreshable { await load() }
        .sheet(item: $opened, onDismiss: { Task { await load() } }) { file in
            LocalProjectEditor(project: project, internalRoot: internalRoot, path: file.path, deleting: deleting, changed: changed)
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
                    return LocalFileEntry(path: (directory.isEmpty ? "" : directory + "/") + child.lastPathComponent, name: child.lastPathComponent, directory: info.isDirectory == true)
                }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        } catch { self.error = error.localizedDescription }
    }
}
