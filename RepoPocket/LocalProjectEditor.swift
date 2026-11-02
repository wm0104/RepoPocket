import SwiftUI
import UIKit

struct LocalProjectEditor: View {
    let project: LocalGitProject
    let internalRoot: URL
    let path: String
    var deleting = false
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fingerprint = ""
    @State private var deletion: LocalGitDeletionTarget?
    @State private var error = ""
    @State private var busy = false
    @State private var attempted = false
    @State private var generation = AccountStore.generation
    @State private var task: Task<Void, Never>?
    @State private var editing = false
    @State private var originalText = ""
    @State private var confirmingClose = false
    private var dirty: Bool { !deleting && text != originalText }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if deleting {
                    Form { Section {
                        Text(path).font(.caption).softGroupedRow(top: true)
                        Text(deletion?.directory == true ? "仅删除此文件夹及其中内容。远端不会立即变化，之后仍需勾选删除记录并提交、推送。" : "只删除这个文件。远端不会立即变化，之后仍需勾选删除记录并提交、推送。").softGroupedRow()
                        if let deletion {
                            Text("\(deletion.files) 个文件 · " + ByteCountFormatter.string(fromByteCount: deletion.bytes, countStyle: .file)).font(.caption).softGroupedRow()
                        }
                        Button(deletion?.directory == true ? "确认删除此文件夹" : "确认删除此文件", role: .destructive) { save() }.disabled(busy || deletion == nil).softGroupedRow(bottom: true)
                    } }
                } else if !fingerprint.isEmpty {
                    SourceCodeEditor(text: $text, filename: path, readOnly: !editing).disabled(busy)
                }
                if busy { ProgressView() }
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
                if fingerprint.isEmpty && !busy && !error.isEmpty { Button("重试读取") { Task { await open() } } }
            }.navigationTitle(deleting ? (deletion?.directory == true ? "删除文件夹" : "删除文件") : (path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { if dirty { confirmingClose = true } else { dismiss() } }.disabled(busy) }
                if !deleting { ToolbarItem(placement: .confirmationAction) {
                    Button(editing ? "保存" : "编辑") { if editing { save() } else { editing = true } }
                        .disabled(busy || fingerprint.isEmpty || (editing && text == originalText))
                } }
            }
            .task { guard !attempted else { return }; attempted = true; await open() }
            .onDisappear { task?.cancel() }
            .interactiveDismissDisabled(busy || dirty)
            .confirmationDialog("保存当前文件的修改？", isPresented: $confirmingClose, titleVisibility: .visible) {
                Button("保存后关闭") { save(closeAfter: true) }
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            } message: { Text(path) }
        }
    }
    private func open() async {
        busy = true; error = ""; deletion = nil; defer { busy = false }
        text = ""; originalText = ""; fingerprint = ""
        do {
            if deleting {
                deletion = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    try LocalGitDeletion.prepare(root: root, path: path) {
                        guard generation == AccountStore.generation else { throw CancellationError() }
                    }
                }
            } else {
                let document = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    try LocalGitFileAccess.read(root: root, path: path)
                }
                try Task.checkCancellation()
                guard generation == AccountStore.generation else { throw CancellationError() }
                text = document.text; originalText = document.text; fingerprint = document.fingerprint
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save(closeAfter: Bool = false) {
        guard !busy else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        busy = true; error = ""
        let value = text, expected = fingerprint, pendingDeletion = deletion
        task = Task { @MainActor in
            defer { busy = false }
            do {
                try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    guard generation == AccountStore.generation else { throw CancellationError() }
                    if deleting {
                        guard let deletion = pendingDeletion else { throw LocalGitError(text: "请重新读取后确认删除。") }
                        try LocalGitDeletion.delete(root: root, target: deletion) {
                            guard generation == AccountStore.generation else { throw CancellationError() }
                        }
                    }
                    else { try LocalGitFileAccess.write(root: root, path: path, text: value, expected: expected) }
                }
                try Task.checkCancellation()
                guard generation == AccountStore.generation else { throw CancellationError() }
                if !deleting {
                    originalText = value
                    fingerprint = LocalGitFileAccess.fingerprint(Data(value.utf8))
                }
                changed()
                if deleting || closeAfter { dismiss() }
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
    var imported: (([String]) -> Void)? = nil
    let changed: () -> Void
    @StateObject private var importer = LocalGitImportState()
    @State private var generation = AccountStore.generation
    @State private var entries: [LocalFileEntry] = []
    @State private var filePresentation = LocalFilePresentation()
    @State private var loaded = false
    @State private var error = ""
    @State private var openDirectory: String?
    @State private var showCreate = false
    @State private var newFolder = false
    @State private var newName = ""
    @State private var creating = false
    @State private var createTask: Task<Void, Never>?
    var body: some View {
        List {
          SoftGroupRows {
            if !directory.isEmpty {
                SoftGroupRow("import-files") { Button("导入文件") { importer.picker = WorkspaceImportRequest(kind: .files) }.disabled(importer.busy || filePresentation.locked) }
                SoftGroupRow("import-folder") { Button("导入文件夹") { importer.picker = WorkspaceImportRequest(kind: .folder) }.disabled(importer.busy || filePresentation.locked) }
            }
            if importer.busy { SoftGroupRow("import-busy") { ProgressView("导入中…") } }
            if !importer.message.isEmpty { SoftGroupRow("import-message") { Text(importer.message).font(.caption).foregroundStyle(.secondary) } }
            for entry in entries {
              SoftGroupRow("entry:" + entry.id) {
                if entry.directory {
                    Button { guard !filePresentation.locked else { return }; openDirectory = entry.path } label: {
                        HStack {
                            Label(entry.name, systemImage: "folder")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(importer.busy)
                    .contextMenu { Button("删除此文件夹", role: .destructive) { openFile(entry.path, deleting: true) }.disabled(importer.busy) }
                } else {
                    Button { openFile(entry.path) } label: {
                        HStack {
                            LocalGitFileLabel(name: entry.name, size: entry.size)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.borderless).disabled(importer.busy)
                        .accessibilityIdentifier("local-project-file-" + entry.path)
                        .contextMenu { Button("删除此文件", role: .destructive) { openFile(entry.path, deleting: true) }.disabled(importer.busy) }
                }
              }
            }
            if loaded && entries.isEmpty && error.isEmpty { SoftGroupRow("empty") { Text("文件夹为空") } }
            if !error.isEmpty { SoftGroupRow("failure") { Text(error).font(.caption).foregroundStyle(.red) } }
          }
        }.disabled(creating).listStyle(.insetGrouped).navigationTitle(directory.isEmpty ? "项目文件" : (directory as NSString).lastPathComponent).adaptiveWorkspaceLayout()
        .task { guard !loaded else { return }; await load() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button("新建文件") { newFolder = false; newName = ""; showCreate = true }
                    Button("新建文件夹") { newFolder = true; newName = ""; showCreate = true }
                } label: { Image(systemName: "plus").accessibilityLabel("新建文件或文件夹") }
                    .disabled(creating || importer.busy || filePresentation.locked)
                Button("刷新列表") { Task { await load() } }.disabled(creating || importer.busy || filePresentation.locked)
            }
        }
        .alert(newFolder ? "新建文件夹" : "新建文件", isPresented: $showCreate) {
            TextField("名称", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("创建") { create() }
            Button("取消", role: .cancel) {}
        } message: { Text(newFolder ? "在当前目录创建。Git 不记录空文件夹，添加文件后才能提交。" : "在当前目录创建空的 UTF-8 文本文件，请包含扩展名，例如 code.swift。") }
        .refreshable { guard !creating, !importer.busy, !filePresentation.locked else { return }; await load() }
        .modifier(LocalGitImportPresentation(importer: importer, project: project, internalRoot: internalRoot,
                                              directory: directory, generation: generation) { paths in
            if let imported { imported(paths) } else { changed() }
            Task { await load() }
        })
        .navigationDestination(isPresented: Binding(get: { openDirectory != nil }, set: { if !$0 { openDirectory = nil } })) {
            if let path = openDirectory {
                LocalProjectFilesView(api: api, project: project, internalRoot: internalRoot, directory: path, imported: imported, changed: changed)
            }
        }
        .onDisappear { importer.cancel(); createTask?.cancel() }
        .sheet(item: Binding(get: { filePresentation.selected }, set: { if $0 == nil { filePresentation.dismissing() } }), onDismiss: {
            filePresentation.didDismiss(); Task { await load() }
        }) { file in
            Group {
                if !file.deleting && file.path.lowercased().hasSuffix(".deb") {
                    LocalProjectDebEditor(api: api, project: project, internalRoot: internalRoot, path: file.path, changed: changed)
                } else {
                    LocalProjectEditor(project: project, internalRoot: internalRoot, path: file.path, deleting: file.deleting, changed: changed)
                }
            }.id(file.id)
        }
    }
    private func openFile(_ path: String, deleting: Bool = false) {
        guard !creating, !importer.busy, importer.picker == nil, !importer.confirmFolder, openDirectory == nil,
              api.isCurrentSession, generation == AccountStore.generation else { return }
        filePresentation.open(path: path, deleting: deleting)
    }
    private func create() {
        guard !creating, !importer.busy, !filePresentation.locked,
              api.isCurrentSession, generation == AccountStore.generation else { return }
        let name = newName, folder = newFolder
        creating = true; error = ""
        createTask = Task { @MainActor in
            defer { creating = false }
            do {
                try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                    try LocalGitFileAccess.create(root: root, directory: directory, name: name, folder: folder)
                }
                try Task.checkCancellation()
                guard api.isCurrentSession, generation == AccountStore.generation else { return }
                changed(); await load()
            } catch { if !RefreshFailure.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
    private func load() async {
        loaded = true; error = ""
        do {
            let result: [LocalFileEntry] = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root -> [LocalFileEntry] in
                let url = directory.isEmpty ? root : try LocalGitFileAccess.path(root: root, relative: directory)
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                guard children.count <= 2000 else { throw LocalGitError(text: "单个目录超过 2000 项，请使用桌面工具。") }
                let result: [LocalFileEntry] = try children.filter { $0.lastPathComponent.lowercased() != ".git" }.compactMap { child -> LocalFileEntry? in
                    let info = try child.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
                    guard info.isSymbolicLink != true else { return nil }
                    let size = try FileManager.default.attributesOfItem(atPath: child.path)[.size] as? NSNumber
                    return LocalFileEntry(path: (directory.isEmpty ? "" : directory + "/") + child.lastPathComponent, name: child.lastPathComponent, directory: info.isDirectory == true, size: size?.int64Value)
                }
                return result.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            try Task.checkCancellation()
            guard api.isCurrentSession, generation == AccountStore.generation else { return }
            entries = result
        } catch { self.error = error.localizedDescription }
    }
}
