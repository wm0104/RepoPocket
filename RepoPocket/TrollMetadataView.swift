import SwiftUI

struct TrollMetadataView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let entry: Entry
    let branch: String
    var canWrite: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var original: TrollMetadataSnapshot?
    @State private var name = ""
    @State private var version = "1.0"
    @State private var detail = ""
    @State private var bundle = ""
    @State private var author = ""
    @State private var notice = ""
    @State private var error = ""
    @State private var busy = false
    @State private var preview = false
    @State private var complete = false
    private var fields: [String: String] { ["name": name, "version": version, "description": detail, "bundle": bundle, "author": author] }
    var body: some View {
        NavigationStack {
            Form {
                Section("已有插件 · 仅修改索引") {
                    Text(repo + "/" + entry.path).softGroupedRow(top: true)
                    Text("不下载、不重新上传 dylib；仅提交根目录 trollpackages.json。").font(.caption).softGroupedRow(bottom: notice.isEmpty)
                    if !notice.isEmpty { Text(notice).foregroundColor(.orange).softGroupedRow(bottom: true) }
                }
                if original != nil && canWrite && api.isCurrentSession {
                    Section("插件元信息") {
                        TextField("名称", text: $name).softGroupedRow(top: true)
                        TextField("版本", text: $version).softGroupedRow()
                        TextField("描述", text: $detail).softGroupedRow()
                        TextField("Bundle ID", text: $bundle).softGroupedRow()
                        TextField("作者", text: $author).softGroupedRow(bottom: true)
                    }
                    if preview {
                        Section("最终预览") {
                            ForEach(fields.keys.sorted(), id: \.self) { key in LabeledContent(key, value: fields[key] ?? "").softGroupedRow(top: key == fields.keys.sorted().first) }
                            Text("只写 trollpackages.json；保留其它条目、URL、section 和未知字段。远端发生变化将拒绝。").softGroupedRow()
                            Button("确认提交元信息") { Task { await save() } }.softGroupedRow()
                            Button("返回修改") { preview = false }.softGroupedRow(bottom: true)
                        }
                    } else { Button("预览修改") { preview = true }.disabled(complete).softGroupedRow(top: true, bottom: true) }
                }
                if busy { ProgressView("处理中，请保持前台").softGroupedRow(top: true, bottom: true) }
                if !error.isEmpty { Section("结果") { Text(error).textSelection(.enabled).softGroupedRow(top: true, bottom: true) } }
            }
            .disabled(busy)
            .navigationTitle("编辑插件信息")
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .task { await load() }
        }
    }
    @MainActor private func load() async {
        guard original == nil else { return }; busy = true; defer { busy = false }
        do {
            let snapshot = try await api.metadataSnapshot(repo: repo, branch: branch, entry: entry)
            let package = try TrollMetadata.package(index: snapshot.index, repo: snapshot.binding.repo, branch: snapshot.binding.branch, path: entry.path)
            name = package?["name"] as? String ?? entry.name
            version = package?["version"] as? String ?? "1.0"
            detail = package?["description"] as? String ?? ""
            bundle = package?["bundle"] as? String ?? ""
            author = package?["author"] as? String ?? ""
            if package == nil { notice = "索引不存在或此文件尚未收录；确认后建立条目。URL 根据当前仓库和实际文件路径生成；使用前请确认该仓库 Pages 已启用。" }
            original = snapshot
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func save() async {
        guard let original else { return }; busy = true; defer { busy = false }
        do { try await api.saveMetadata(original, fields: fields); error = "元信息已提交；dylib 未改动。"; complete = true; preview = false }
        catch { self.error = error.localizedDescription }
    }
}
