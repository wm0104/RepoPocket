import SwiftUI

/// Reuses the established DEB editor; only explicit Save replaces the local file.
struct LocalProjectDebEditor: View {
    @ObservedObject var api: GitHub
    let project: LocalGitProject
    let internalRoot: URL
    let path: String
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var generation = AccountStore.generation
    @State private var source: URL?
    @State private var fingerprint = ""
    @State private var failure = ""
    @State private var attempted = false
    var body: some View {
        Group {
            if let source {
                DebEditorView(api: api, initialFile: source, onSaveLocal: { output in
                    guard generation == AccountStore.generation else { throw CancellationError() }
                    let expected = fingerprint
                    try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                        _ = try DebControlEditor.fields(at: output)
                        try LocalGitFileAccess.replaceBinary(root: root, path: path, source: output, expected: expected)
                    }
                    changed()
                })
            } else {
                NavigationStack {
                    VStack(spacing: 12) {
                        if failure.isEmpty { ProgressView("读取本地 DEB…") }
                        else { Text(failure); Button("重试") { Task { await load() } } }
                    }.padding().navigationTitle("编辑 deb 包信息")
                        .toolbar { Button("关闭") { dismiss() } }
                }
            }
        }.task { guard !attempted else { return }; attempted = true; await load() }
    }
    private func load() async {
        failure = ""
        do {
            let prepared: (URL, String) = try await LocalGitEngine.shared.file(project: project, internalRoot: internalRoot, generation: generation) { root in
                let input = try LocalGitFileAccess.path(root: root, relative: path)
                return try LocalGitFileAccess.coordinate(input, writing: false) { coordinated in
                    let expected = try LocalGitFileAccess.fileFingerprint(root: root, path: path)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RepoPocket-local-deb-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let output = folder.appendingPathComponent(input.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: coordinated, to: output)
                        guard try LocalGitFileAccess.fileFingerprint(root: folder, path: output.lastPathComponent) == expected else {
                            throw LocalGitError(text: "读取期间原文件发生变化，请重新打开。")
                        }
                        return (output, expected)
                    } catch { try? FileManager.default.removeItem(at: folder); throw error }
                }
            }
            try Task.checkCancellation()
            guard generation == AccountStore.generation else { return }
            fingerprint = prepared.1; source = prepared.0
        } catch { if !RefreshFailure.isCancellation(error) { failure = error.localizedDescription } }
    }
}
