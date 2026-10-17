import SwiftUI
import UniformTypeIdentifiers

/// The source and output live in this screen's private temporary folder until dismissal.
struct DebEditorView: View {
    @ObservedObject var api: GitHub
    var remote: (repo: String, entry: Entry, branch: String)? = nil
    var canWrite: Bool = false
    var initialFile: URL? = nil
    var onSaveLocal: ((URL) async throws -> Void)? = nil
    var onUseForUpload: ((URL) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var source: URL?
    @State private var output: URL?
    @State private var original: [String: String] = [:]
    @State private var package = ""
    @State private var version = ""
    @State private var description = ""
    @State private var maintainer = ""
    @State private var name = ""
    @State private var author = ""
    @State private var section = ""
    @State private var priority = ""
    @State private var homepage = ""
    @State private var showPicker = false
    @State private var showUpload = false
    @State private var remoteHead = ""
    @State private var remoteBranch = ""
    @State private var remoteEntry: Entry?
    @State private var commitNote = "Edit deb metadata"
    @State private var confirmRemote = false
    @State private var submitted = false
    @State private var resultMessage = ""
    @State private var busy = false
    @State private var error = ""
    @State private var didLoad = false

    private var current: [String: String] {
        var fields = ["Package": package, "Version": version, "Description": description, "Maintainer": maintainer]
        for (name, value) in [("Name", name), ("Author", author), ("Section", section), ("Priority", priority), ("Homepage", homepage)] where original[name] != nil { fields[name] = value }
        return fields
    }
    private var differences: [(String, String, String)] {
        ["Name", "Package", "Version", "Description", "Maintainer", "Author", "Section", "Priority", "Homepage"].compactMap { key in
            guard let before = original[key], let after = current[key], before != after else { return nil }
            return (key, before, after)
        }
    }
    var body: some View {
        NavigationStack {
            editorPresentation
        }
    }

    private var editorForm: some View {
        Form {
            sourceSection
            if !original.isEmpty {
                originalSection
                editSection
                differencesSection
            }
            if let output {
                outputSection(output)
            }
        }
    }

    private var sourceSection: some View {
        Section("源文件") {
            if remote == nil && initialFile == nil { Button("从“文件”选择 .deb") { showPicker = true }.disabled(busy).softGroupedRow(top: true) }
            if let source { Text(source.lastPathComponent).softGroupedRow(top: remote != nil || initialFile != nil); Text(onSaveLocal == nil ? "只修改副本；原文件不会覆盖" : "先编辑副本，点击“保存到本地项目”才更新原文件").font(.caption).foregroundColor(.secondary).softGroupedRow() }
            if busy { ProgressView("读取 / 生成中，请保持前台").softGroupedRow(top: source == nil && (remote != nil || initialFile != nil)) }
            Text("支持 control.tar、gz、xz、zst；xz/zst 编辑后输出 gzip。bz2/lzma 暂不支持编辑，但仍可原样上传。").font(.caption).foregroundColor(.secondary).softGroupedRow(top: source == nil && !busy && (remote != nil || initialFile != nil), bottom: true)
        }
    }

    private var originalKeys: [String] { ["Name", "Package", "Version", "Description", "Maintainer", "Author", "Section", "Priority", "Homepage"].filter { original[$0] != nil } }
    private var originalSection: some View {
        Section("原始包信息") {
            ForEach(originalKeys, id: \.self) { key in
                if let value = original[key] { LabeledContent(key, value: value).textSelection(.enabled).softGroupedRow(top: key == originalKeys.first, bottom: key == originalKeys.last) }
            }
        }
    }

    private var editSection: some View {
        Section("编辑") {
            if original["Name"] != nil { TextField("Name（显示名称）", text: $name).softGroupedRow(top: true) }
            if original["Author"] != nil { TextField("Author", text: $author).softGroupedRow(top: original["Name"] == nil) }
            TextField("Package（包标识）", text: $package).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow(top: original["Name"] == nil && original["Author"] == nil)
            TextField("Version", text: $version).textInputAutocapitalization(.never).autocorrectionDisabled().softGroupedRow()
            TextField("Maintainer", text: $maintainer).softGroupedRow()
            Text("Description（多行可编辑）").font(.caption).softGroupedRow()
            TextEditor(text: $description).frame(minHeight: 85).softGroupedRow()
            if original["Section"] != nil { TextField("Section", text: $section).softGroupedRow() }
            if original["Priority"] != nil { TextField("Priority", text: $priority).softGroupedRow() }
            if original["Homepage"] != nil { TextField("Homepage", text: $homepage).textInputAutocapitalization(.never).softGroupedRow() }
            Text("其他 control 字段原样保留；仅已存在的可选字段允许修改。空值或不合法格式将被拒绝。").font(.caption).foregroundColor(.secondary).softGroupedRow(bottom: true)
        }
    }

    private var differencesSection: some View {
        Section("变更对照") {
            if differences.isEmpty { Text("尚无修改").foregroundColor(.secondary).softGroupedRow(top: true) }
            ForEach(differences.indices, id: \.self) { index in
                differenceRow(differences[index]).softGroupedRow(top: index == differences.startIndex)
            }
            Button("生成新的 deb（验证后保存）") { Task { await generate() } }.disabled(busy || differences.isEmpty).softGroupedRow(bottom: true)
        }
    }

    private func differenceRow(_ item: (String, String, String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.0).font(.headline)
            Text("原：" + item.1).foregroundColor(.secondary)
            Text("新：" + item.2)
        }.textSelection(.enabled)
    }

    private func outputSection(_ output: URL) -> some View {
        Section("已生成 · 未替换原文件") {
            Text(output.lastPathComponent).softGroupedRow(top: true)
            ShareLink(item: output, preview: SharePreview(output.lastPathComponent)) { Label("分享 / 存储到“文件”", systemImage: "square.and.arrow.up") }.softGroupedRow()
            if remote != nil && canWrite && api.isCurrentSession {
                TextField("提交说明（可选）", text: $commitNote).softGroupedRow()
                if confirmRemote {
                    Text("确认只更新原仓库文件：" + (remoteEntry?.path ?? "")).softGroupedRow()
                    Button("确认提交回原文件") { Task { await submitRemote(output) } }.disabled(busy || submitted).softGroupedRow()
                    Button("取消确认") { confirmRemote = false }.softGroupedRow()
                } else {
                    Button("提交回原文件") { confirmRemote = true }.disabled(busy || submitted).softGroupedRow()
                }
                if !resultMessage.isEmpty { Text(resultMessage).softGroupedRow() }
            } else if remote != nil {
                Text("此仓库为只读，生成文件仅可保存到本地。").softGroupedRow()
            } else if let onSaveLocal {
                Button("保存到本地项目") {
                    Task { @MainActor in
                        busy = true; defer { busy = false }
                        do { try await onSaveLocal(output); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy).softGroupedRow()
            } else if let onUseForUpload {
                Button("使用新 deb 提交 / 发布") { onUseForUpload(output) }.disabled(busy).softGroupedRow()
            } else {
                Button("使用新 deb 提交 / 发布") { showUpload = true }.disabled(busy).softGroupedRow()
            }
            Text(onSaveLocal == nil ? "提交仓库须明确选择目录及目标；Release 只上传附件，不会自动公开发布。" : "保存只更新当前本地 DEB，之后需创建本地提交并推送；其他项目文件不变。").font(.caption).softGroupedRow(bottom: true)
        }
    }

    private var editorNavigation: some View {
        editorForm
            .navigationTitle("编辑 deb 包信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy || showUpload) } }
            .interactiveDismissDisabled(busy || showUpload)
    }

    private var editorPresentation: some View {
        editorNavigation
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [UTType(filenameExtension: "deb") ?? .data, .data], allowsMultipleSelection: false) { result in
                Task { @MainActor in
                    do { guard let url = try result.get().first else { return }; await prepare(url, scoped: true) }
                    catch { self.error = error.localizedDescription }
                }
            }
            .sheet(isPresented: $showUpload) {
                if let output { UploadView(api: api, initialRepo: remote?.repo ?? "", initialBranch: remote?.branch ?? "", initialFile: output, openedFromFolder: true) }
            }
            .alert("无法编辑 deb", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
            .task {
                guard !didLoad else { return }; didLoad = true
                if let remote {
                    busy = true
                    do {
                        let resolved = try await api.resolvedBranch(remote.repo, branch: remote.branch)
                        let head = try await api.workspaceHead(remote.repo, branch: resolved)
                        let entry = try await api.file(remote.repo, path: remote.entry.path, branch: head)
                        guard entry.sha == remote.entry.sha else { throw AppError(text: "远端文件已变化，请关闭并刷新") }
                        remoteHead = head; remoteBranch = resolved; remoteEntry = entry
                        let url = try await api.downloadFile(remote.repo, entry: entry, branch: head)
                        await prepare(url, scoped: false)
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                    catch { self.error = error.localizedDescription }
                    busy = false
                } else if let initialFile { await prepare(initialFile, scoped: false) }
            }
            // Do not delete files on disappearance: navigation/share sheets still own URLs.
            // Generated directories survive until OS temporary-file reclamation.
    }
    @MainActor private func submitRemote(_ output: URL) async {
        guard let remote, let entry = remoteEntry else { error = "请重新载入远端文件"; return }
        busy = true; defer { busy = false }
        do {
            try await api.saveRemoteDeb(repo: remote.repo, branch: remoteBranch, head: remoteHead, entry: entry, output: output, message: commitNote)
            submitted = true; confirmRemote = false; resultMessage = "已提交回原文件；本地原 deb 副本和生成包仍可保存。"
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func prepare(_ url: URL, scoped: Bool) async {
        busy = true; defer { busy = false }
        let accessed = scoped && url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "deb" else { throw AppError(text: "只允许选择 .deb 文件") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(url.lastPathComponent)
            do { try FileManager.default.copyItem(at: url, to: copy)
                let fields = try await Task.detached(priority: .userInitiated) { try DebControlEditor.fields(at: copy) }.value
                if let old = folder { try? FileManager.default.removeItem(at: old) }
                folder = dir; source = copy; output = nil; original = fields
                package = fields["Package"] ?? ""; version = fields["Version"] ?? ""
                description = fields["Description"] ?? ""; maintainer = fields["Maintainer"] ?? ""
                name = fields["Name"] ?? ""; author = fields["Author"] ?? ""
                section = fields["Section"] ?? ""; priority = fields["Priority"] ?? ""; homepage = fields["Homepage"] ?? ""
            } catch { try? FileManager.default.removeItem(at: dir); throw error }
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func generate() async {
        guard let source else { return }
        busy = true; defer { busy = false }
        do {
            let optional = ["Name": name, "Author": author, "Section": section, "Priority": priority, "Homepage": homepage].filter { original[$0.key] != nil }
            let changes = DebControlEditor.Changes(package: package, version: version, description: description, maintainer: maintainer, optionalFields: optional)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(source.lastPathComponent)
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: dir) } }
            try await Task.detached(priority: .userInitiated) {
                try DebControlEditor.edit(input: source, output: target, changes: changes)
                let verified = try DebControlEditor.fields(at: target)
                let expected = ["Package": changes.package, "Version": changes.version, "Description": changes.description, "Maintainer": changes.maintainer].merging(changes.optionalFields) { first, _ in first }
                guard expected.allSatisfy({ verified[$0.key] == $0.value }) else { throw AppError(text: "生成文件的字段校验未通过") }
            }.value
            // Keep earlier generated copies until dismissal: an open share sheet may still read them.
            completed = true
            output = target
        } catch { self.error = error.localizedDescription }
    }
}

