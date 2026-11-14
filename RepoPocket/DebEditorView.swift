import SwiftUI
import UniformTypeIdentifiers

/// The source and output live in this screen's private temporary folder until dismissal.
struct DebEditorView: View {
    @ObservedObject var api: GitHub
    var remote: (repo: String, entry: Entry, branch: String)? = nil
    var canWrite: Bool = false
    var initialFile: URL? = nil
    var onSaveLocal: ((URL) async throws -> Void)? = nil
    var onUseForUpload: ((URL) throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var source: URL?
    @State private var output: URL?
    @State private var original: [String: String] = [:]
    @State private var package = ""
    @State private var version = ""
    @State private var description = ""
    @State private var releaseDate = ""
    @State private var changelog = ""
    @State private var maintainer = ""
    @State private var name = ""
    @State private var author = ""
    @State private var section = ""
    @State private var priority = ""
    @State private var homepage = ""
    @State private var showPicker = false
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
    @State private var originalExpanded = false
    @State private var moreExpanded = false
    @State private var differencesExpanded = false

    private var current: [String: String] {
        var fields = ["Package": package, "Version": version, "Description": description, "Maintainer": maintainer]
        for (name, value) in [("Name", name), ("Author", author), ("Section", section), ("Priority", priority), ("Homepage", homepage)] where original[name] != nil { fields[name] = value }
        fields.merge(releaseChanges) { _, new in new }
        return fields
    }
    private var releaseChanges: [String: String] {
        // Keep invalid edits in the difference list; generation presents the validation error.
        (try? DebControlEditor.releaseFields(package: package, originalPackage: original["Package"] ?? "",
                                             version: version, date: releaseDate, changelog: changelog))
            ?? ["X-WM0104-Release-Date": releaseDate, "X-WM0104-Changelog": changelog]
    }
    private var differences: [(String, String, String)] {
        (["Name", "Package", "Version", "Description", "Maintainer", "Author", "Section", "Priority", "Homepage"] + ["X-WM0104-Release-Date", "X-WM0104-Changelog", "X-RepoPocket-Changelog"].filter { releaseChanges[$0] != nil }).compactMap { key in
            let before = original[key] ?? "", after = current[key] ?? ""
            guard before != after else { return nil }
            return (key, before, after)
        }
    }
    var body: some View {
        AppNavigationStack {
            editorPresentation
        }
    }

    private var showsOutput: Bool { output != nil && onUseForUpload == nil }
    private var editorForm: some View {
        Form {
            Section {
            sourceSection
            if !original.isEmpty {
                editSection
                originalSection
                if !differences.isEmpty { differencesSection }
            }
            if let output, onUseForUpload == nil {
                outputSection(output)
            }
            }
        }
    }

    private var sourceSection: some View {
        SoftGroupRows(bottom: original.isEmpty && !showsOutput) {
                SoftGroupRow("source-heading") { Text("源文件").font(.subheadline).foregroundStyle(.secondary) }
                if remote == nil && initialFile == nil {
                    SoftGroupRow("choose") { Button("从“文件”选择 .deb") { showPicker = true }.disabled(busy) }
                }
                if let file = source ?? initialFile {
                    SoftGroupRow("file") { Text(file.lastPathComponent) }
                }
                SoftGroupRow("copy") {
                    Text(onSaveLocal == nil ? "只修改副本；原文件不会覆盖" : "先编辑副本，点击“保存到本地项目”才更新原文件").font(.caption).foregroundColor(.secondary)
                }
                if remote != nil && (!canWrite || !api.isCurrentSession) {
                    SoftGroupRow("readonly") { Text("此仓库为只读，生成文件仅可保存到本地。").font(.caption).foregroundColor(.secondary) }
                }
                if busy { SoftGroupRow("progress") { ProgressView("读取 / 生成中，请保持前台") } }
        }
    }

    private var originalKeys: [String] { ["Name", "Package", "Version", "Description", "Maintainer", "Author", "Section", "Priority", "Homepage", "X-WM0104-Release-Date", "X-WM0104-Changelog", "X-RepoPocket-Changelog"].filter { original[$0] != nil } }
    private var originalSection: some View {
        SoftGroupRows(top: false, bottom: differences.isEmpty && !showsOutput) {
                SoftGroupRow("original") {
                    Button { UIRules.withoutAnimation { originalExpanded.toggle() } } label: {
                        HStack { Text("原始包信息"); Spacer(); Image(systemName: originalExpanded ? "chevron.up" : "chevron.down").font(.caption) }
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("deb-original")
                }
                if originalExpanded {
                    for key in originalKeys {
                        SoftGroupRow(key) { AppLabeledContent(key, value: original[key] ?? "").textSelection(.enabled) }
                    }
                    SoftGroupRow("formats") {
                        Text("支持 control.tar、gz、xz、zst；xz/zst 编辑后输出 gzip。bz2/lzma 暂不支持编辑，但仍可原样上传。").font(.caption).foregroundColor(.secondary)
                    }
                }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var editSection: some View {
        SoftGroupRows(top: false, bottom: false) {
                SoftGroupRow("edit-heading") { Text("编辑").font(.subheadline).foregroundStyle(.secondary) }
                if original["Name"] != nil { SoftGroupRow("name") { TextField("Name（显示名称）", text: $name) } }
                SoftGroupRow("package") { TextField("Package（包标识）", text: $package).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("deb-package") }
                SoftGroupRow("version") { TextField("Version", text: $version).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("deb-version") }
                SoftGroupRow("description-label") { Text("Description（多行可编辑）").font(.caption) }
                SoftGroupRow("description") { TextEditor(text: $description).frame(minHeight: 85) }
                SoftGroupRow("release-date") { TextField("发布日期（YYYY-MM-DD）", text: $releaseDate).textInputAutocapitalization(.never).disableAutocorrection(true).accessibilityIdentifier("deb-release-date") }
                SoftGroupRow("changelog-label") { Text("当前版本更新信息（每行一条）").font(.caption) }
                SoftGroupRow("changelog") { TextEditor(text: $changelog).frame(minHeight: 85).accessibilityIdentifier("deb-changelog") }
                SoftGroupRow("changelog-format") { Text("Markdown 标记（如 **粗体**）原样保存；兼容的源生成器按每行一条列表项显示。不能包含“；”或“ | ”；清空会删除更新信息，发布日期仍保存。修改版本号后，当前输入按新版本保存。").font(.caption).foregroundColor(.secondary) }
                SoftGroupRow("maintainer") { TextField("Maintainer", text: $maintainer) }
                if ["Author", "Section", "Priority", "Homepage"].contains(where: { original[$0] != nil }) {
                    SoftGroupRow("more") {
                        Button { UIRules.withoutAnimation { moreExpanded.toggle() } } label: {
                            HStack { Text("更多字段"); Spacer(); Image(systemName: moreExpanded ? "chevron.up" : "chevron.down").font(.caption) }
                                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("deb-more-fields")
                    }
                    if moreExpanded {
                        if original["Author"] != nil { SoftGroupRow("author") { TextField("Author", text: $author).accessibilityIdentifier("deb-author") } }
                        if original["Section"] != nil { SoftGroupRow("section") { TextField("Section", text: $section) } }
                        if original["Priority"] != nil { SoftGroupRow("priority") { TextField("Priority", text: $priority) } }
                        if original["Homepage"] != nil { SoftGroupRow("homepage") { TextField("Homepage", text: $homepage).textInputAutocapitalization(.never) } }
                    }
                }
                SoftGroupRow("preserved") { Text("其他 control 字段原样保留；仅已存在的可选字段允许修改。空值或不合法格式将被拒绝。").font(.caption).foregroundColor(.secondary) }
        }.disabled(busy).transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var differencesSection: some View {
        SoftGroupRows(top: false, bottom: !showsOutput) {
                SoftGroupRow("summary") {
                    Button { UIRules.withoutAnimation { differencesExpanded.toggle() } } label: {
                        HStack {
                            Text("变更对照（\(differences.count)）")
                            Spacer()
                            Image(systemName: differencesExpanded ? "chevron.up" : "chevron.down").font(.caption)
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("deb-differences")
                }
                if differencesExpanded {
                    for item in differences {
                        SoftGroupRow(item.0) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.0).font(.headline)
                                Text("原：" + item.1).foregroundColor(.secondary)
                                Text("新：" + item.2)
                            }.textSelection(.enabled)
                        }
                    }
                }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func outputSection(_ output: URL) -> some View {
        Group {
            Text("已生成 · 未替换原文件").font(.subheadline).foregroundStyle(.secondary).softGroupedRow()
            Text(output.lastPathComponent).softGroupedRow()
            if remote != nil || onSaveLocal != nil {
                AppShareLink(item: output, previewTitle: output.lastPathComponent) { Label("分享 / 存储到“文件”", systemImage: "square.and.arrow.up") }.softGroupedRow()
            }
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
            } else if onUseForUpload == nil {
                ExternalFileActions(api: api, file: output).disabled(busy).softGroupedRow()
            }
            Text(onSaveLocal == nil ? "提交仓库须明确选择目录及目标；Release 只上传附件，不会自动公开发布。" : "保存只更新当前本地 DEB，之后需创建本地提交并推送；其他项目文件不变。").font(.caption).softGroupedRow(bottom: true)
        }
    }

    private var editorNavigation: some View {
        editorForm
            .accessibilityIdentifier("deb-editor-form")
            .navigationTitle("编辑 deb 包信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if !original.isEmpty {
                        Button(onUseForUpload == nil ? "生成副本" : "保存并返回") { Task { await generate() } }
                            .disabled(busy || differences.isEmpty)
                            .accessibilityLabel(onUseForUpload == nil ? "生成新的 deb（验证后保存）" : "保存并返回上传队列")
                            .accessibilityIdentifier("deb-generate")
                    }
                }
            }
            .interactiveDismissDisabled(busy)
    }

    private var editorPresentation: some View {
        editorNavigation
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [UTType(filenameExtension: "deb") ?? .data, .data], allowsMultipleSelection: false) { result in
                Task { @MainActor in
                    do { guard let url = try result.get().first else { return }; await prepare(url, scoped: true) }
                    catch { self.error = error.localizedDescription }
                }
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
                let release = DebControlEditor.releaseInformation(fields: fields)
                releaseDate = release.date; changelog = release.changelog
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
            let changes = DebControlEditor.Changes(package: package, version: version, description: description, maintainer: maintainer, optionalFields: optional, releaseDate: releaseDate, changelog: changelog)
            let release = try DebControlEditor.releaseFields(package: package, originalPackage: original["Package"] ?? "", version: version, date: releaseDate, changelog: changelog)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(source.lastPathComponent)
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: dir) } }
            try await Task.detached(priority: .userInitiated) {
                try DebControlEditor.edit(input: source, output: target, changes: changes)
                let verified = try DebControlEditor.fields(at: target)
                let expected = ["Package": changes.package, "Version": changes.version, "Description": changes.description, "Maintainer": changes.maintainer].merging(changes.optionalFields) { first, _ in first }.merging(release) { _, new in new }
                guard expected.allSatisfy({ verified[$0.key] == ($0.value.isEmpty ? nil : $0.value) }) else { throw AppError(text: "生成文件的字段校验未通过") }
            }.value
            // Keep earlier generated copies until dismissal: an open share sheet may still read them.
            if let onUseForUpload {
                try onUseForUpload(target)
                // The queue owns its verified copy before this editor is dismissed.
                try? FileManager.default.removeItem(at: dir)
                dismiss()
            } else {
                completed = true
                output = target
            }
        } catch { self.error = error.localizedDescription }
    }
}

