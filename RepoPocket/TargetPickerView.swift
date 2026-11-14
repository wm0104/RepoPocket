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
    let selected: (String, Entry?) -> Void
    @State private var entries: [Entry] = []
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        List {
            Section {
                Text(repo).font(.caption)
                Text(path.isEmpty ? "根目录 /" : path).font(.caption)
                if !filesOnly { Button("上传到此文件夹") { selected(path, nil) } }
            }
            if busy { ProgressView() }
            if !error.isEmpty {
                Text(error).foregroundColor(.red)
                Button("重试") { Task { await load() } }
            }
            Section("文件夹") {
                ForEach(entries.filter { $0.type == "dir" }) { e in
                    NavigationLink {
                        TargetPickerView(api: api, repo: repo, branch: branch, path: e.path, filesOnly: filesOnly, selected: selected)
                    } label: { Label(e.name, systemImage: "folder") }
                }
            }
            Section(filesOnly ? "选择删除文件" : "替换已有文件") {
                ForEach(entries.filter { $0.type == "file" }) { e in
                    Button { selected((e.path as NSString).deletingLastPathComponent, e) } label: {
                        Label(e.name, systemImage: "doc")
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
