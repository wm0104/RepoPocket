import SwiftUI

@MainActor final class LocalGitImportState: ObservableObject {
    @Published var picker: WorkspaceImportRequest?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published var confirmFolder = false
    private var pending: LocalGitImportSources?
    func retainFolder(_ urls: [URL]?) {
        guard !busy, let urls, !urls.isEmpty else { return }
        pending = LocalGitImportSources(urls)
    }
    func presentFolderConfirmation() { confirmFolder = pending != nil }
    func takeFolder() -> LocalGitImportSources? { defer { pending = nil }; return pending }
    func discardFolder() { pending = nil }
    private var task: Task<Void, Never>?
    func accept(_ urls: [URL]?, project: LocalGitProject, internalRoot: URL, directory: String,
                generation: UUID, changed: @escaping ([String]) -> Void) {
        guard !busy, let urls, !urls.isEmpty else { return }
        // Acquire access inside the picker callback, before its dismissal.
        let sources = LocalGitImportSources(urls)
        accept(sources, project: project, internalRoot: internalRoot, directory: directory, generation: generation, changed: changed)
    }
    func accept(_ sources: LocalGitImportSources, project: LocalGitProject, internalRoot: URL, directory: String,
                replaceExisting: Bool = false, generation: UUID, changed: @escaping ([String]) -> Void) {
        guard !busy else { return }
        busy = true; message = ""
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            var importedPaths: [String] = []
            do {
                let result = try await LocalGitEngine.shared.importFiles(sources, project: project,
                    internalRoot: internalRoot, directory: directory, replaceExisting: replaceExisting, generation: generation)
                guard generation == AccountStore.generation else { return }
                importedPaths = result.paths
                message = "已导入 \(result.paths.count) 个文件，保留原目录结构。" + (result.skipped.isEmpty ? "" : "已跳过 \(result.skipped.count) 个同名文件。") + "变化文件已选中，可一次创建本地提交后推送；相同内容不产生新提交。"
            } catch {
                guard generation == AccountStore.generation else { return }
                message = error is CancellationError ? "导入已取消，已完成的文件保留；请检查变化。" : error.localizedDescription
            }
            // A cancelled provider operation can have published an item already.
            // Always invalidate the old status instead of retaining stale choices.
            if generation == AccountStore.generation { changed(importedPaths) }
        }
    }
    func cancel() { task?.cancel() }
}

struct LocalGitImportPresentation: ViewModifier {
    @ObservedObject var importer: LocalGitImportState
    let project: LocalGitProject
    let internalRoot: URL
    var directory = ""
    let generation: UUID
    let changed: ([String]) -> Void
    func body(content: Content) -> some View {
        content.sheet(item: $importer.picker, onDismiss: { importer.presentFolderConfirmation() }) { request in
            WorkspaceDocumentPicker(request: request, allowsMultipleSelection: request.kind != .folder) { urls in
                if request.kind == .folder { importer.retainFolder(urls) }
                else { importer.accept(urls, project: project, internalRoot: internalRoot, directory: directory, generation: generation, changed: changed) }
                importer.picker = nil
            }.id(request.id)
        }
        .confirmationDialog("导入整个文件夹", isPresented: $importer.confirmFolder, titleVisibility: .visible) {
            Button("导入全部，更新同名文件") { start(replaceExisting: true) }
            Button("仅补入新文件，保留同名文件") { start(replaceExisting: false) }
            Button("取消", role: .cancel) { importer.discardFolder() }
        } message: {
            Text("包含全部文件和子文件夹，保留目录结构，不需要逐个勾选。更新同名文件只在当前本地项目生效，未选的其他文件保留；之后仍需确认提交、推送。")
        }
    }
    private func start(replaceExisting: Bool) {
        guard let sources = importer.takeFolder() else { return }
        importer.accept(sources, project: project, internalRoot: internalRoot, directory: directory,
                        replaceExisting: replaceExisting, generation: generation, changed: changed)
    }
}
