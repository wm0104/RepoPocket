import SwiftUI

/// Folder-only browser used to choose where an import should land.
struct LocalGitDirectoryPicker: View {
    let project: LocalGitProject
    let internalRoot: URL
    var directory = ""
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [Folder] = []
    @State private var error = ""
    @State private var loaded = false

    struct Folder: Identifiable, Hashable {
        let name: String
        let path: String
        var id: String { path }
    }

    var body: some View {
        List {
            Section {
                Button {
                    onPick(directory)
                    dismiss()
                } label: {
                    Label(directory.isEmpty ? "选择根目录" : "选择此文件夹", systemImage: "checkmark.circle")
                }
            }
            Section("文件夹") {
                ForEach(folders) { folder in
                    NavigationLink(folder.name) {
                        LocalGitDirectoryPicker(project: project, internalRoot: internalRoot, directory: folder.path, onPick: onPick)
                    }
                }
                if loaded && folders.isEmpty {
                    Text("没有子文件夹").foregroundStyle(.secondary)
                }
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(directory.isEmpty ? "选择导入位置" : (directory as NSString).lastPathComponent)
        .task { guard !loaded else { return }; await load() }
    }

    private func load() async {
        loaded = true
        do {
            folders = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot) { root in
                let url = directory.isEmpty ? root : try LocalGitFileAccess.path(root: root, relative: directory)
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard children.count <= 2000 else { throw LocalGitError(text: "单个目录超过 2000 项，请使用桌面工具。") }
                return try children.filter { $0.lastPathComponent.lowercased() != ".git" }.compactMap { child -> Folder? in
                    let info = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard info.isSymbolicLink != true, info.isDirectory == true else { return nil }
                    let name = child.lastPathComponent
                    return Folder(name: name, path: (directory.isEmpty ? "" : directory + "/") + name)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
