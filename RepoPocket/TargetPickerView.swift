import SwiftUI

struct RepositoryTarget: Identifiable {
    let id = UUID()
    let repo: String
    let branch: String
    let path: String
    let head: String
}

struct TargetPickerView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let branch: String
    let path: String
    var filesOnly = false
    var foldersOnly = false
    let selected: (String, Entry?) -> Void
    @State private var entries: [Entry] = []
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        List {
            Section {
                SoftGroupRows {
                    SoftGroupRow("repository") { Text(repo).font(.caption) }
                    SoftGroupRow("path") { Text(path.isEmpty ? "根目录 /" : path).font(.caption) }
                    if !path.isEmpty {
                        SoftGroupRow("parent") {
                            NavigationLink("上级目录") {
                                TargetPickerView(api: api, repo: repo, branch: branch, path: (path as NSString).deletingLastPathComponent, filesOnly: filesOnly, foldersOnly: foldersOnly, selected: selected)
                            }
                        }
                    }
                    if !filesOnly { SoftGroupRow("select-folder") { Button("上传到此文件夹") { selected(path, nil) } } }
                    if busy { SoftGroupRow("busy") { ProgressView() } }
                    if !error.isEmpty {
                        SoftGroupRow("error") { Text(error).foregroundColor(.red) }
                        SoftGroupRow("retry") { Button("重试") { Task { await load() } } }
                    }
                    SoftGroupRow("folders-title") { Text("文件夹").font(.caption).foregroundStyle(.secondary) }
                    for e in entries.filter({ $0.type == "dir" }) {
                        SoftGroupRow("folder-" + e.path) {
                            NavigationLink {
                                TargetPickerView(api: api, repo: repo, branch: branch, path: e.path, filesOnly: filesOnly, foldersOnly: foldersOnly, selected: selected)
                            } label: { Label(e.name, systemImage: "folder") }
                        }
                    }
                    if !foldersOnly {
                        SoftGroupRow("files-title") { Text(filesOnly ? "选择删除文件" : "替换已有文件").font(.caption).foregroundStyle(.secondary) }
                        for e in entries.filter({ $0.type == "file" }) {
                            SoftGroupRow("file-" + e.path) {
                                Button { selected((e.path as NSString).deletingLastPathComponent, e) } label: {
                                    Label(e.name, systemImage: "doc")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(path.isEmpty ? "选择位置" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
    private func load() async {
        busy = true; error = ""; defer { busy = false }
        do { entries = try await api.contents(repo, path: path, branch: branch) }
        catch { self.error = error.localizedDescription }
    }
}
