#if DEBUG
import SwiftUI

/// The workflow creates a real repository in Simulator Documents before launching.
/// This route exercises the shipping registry, native Git engine and project screens.
struct LocalGitStylePreview: View {
    @StateObject private var api = GitHub()
    @StateObject private var store = LocalGitRegistry(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("LocalGitStylePreview", isDirectory: true))
    @State private var project: LocalGitProject?
    @State private var failure = ""

    var body: some View {
        NavigationStack {
            Group {
                if let project {
                    LocalProjectView(api: api, store: store, project: project)
                } else if !failure.isEmpty {
                    Text("本地 Git 预览准备失败：" + failure).padding()
                } else {
                    ProgressView("准备本地 Git 预览…")
                }
            }
        }
        .task {
            guard project == nil, failure.isEmpty else { return }
            do {
                let root = store.internalRoot.appendingPathComponent("本地提交预览", isDirectory: true)
                let prepared = try store.prepare(root)
                try store.attach(prepared)
                project = prepared
            } catch { failure = error.localizedDescription }
        }
    }
}
#endif
