import SwiftUI

@MainActor final class LocalGitImportState: ObservableObject {
    @Published var picker: WorkspaceImportRequest?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var task: Task<Void, Never>?
    func accept(_ urls: [URL]?, project: LocalGitProject, internalRoot: URL, directory: String,
                generation: UUID, changed: @escaping () -> Void) {
        guard !busy, let urls, !urls.isEmpty else { return }
        // Acquire access inside the picker callback, before its dismissal.
        let sources = LocalGitImportSources(urls)
        busy = true; message = ""
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let result = try await LocalGitEngine.shared.importFiles(sources, project: project,
                    internalRoot: internalRoot, directory: directory, generation: generation)
                guard generation == AccountStore.generation else { return }
                message = result.paths.isEmpty ? "已导入空文件夹；Git 不记录空文件夹。" : "已导入 \(result.paths.count) 个文件，请勾选后创建本地提交。"
            } catch {
                guard generation == AccountStore.generation else { return }
                message = error is CancellationError ? "导入已取消，已完成的文件保留；请检查变化。" : error.localizedDescription
            }
            // A cancelled provider operation can have published an item already.
            // Always invalidate the old status instead of retaining stale choices.
            if generation == AccountStore.generation { changed() }
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
    let changed: () -> Void
    func body(content: Content) -> some View {
        content.sheet(item: $importer.picker) { request in
            WorkspaceDocumentPicker(request: request) { urls in
                importer.accept(urls, project: project, internalRoot: internalRoot, directory: directory,
                                generation: generation, changed: changed)
                importer.picker = nil
            }.id(request.id)
        }
    }
}
