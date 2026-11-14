import SwiftUI

private struct DownloadCompletionNotice: ViewModifier {
    @Binding var file: URL?
    func body(content: Content) -> some View {
        content.background {
            // Keep this presenter separate from the page's copy/upload/error alerts.
            Color.clear.alert("下载完成", isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }), presenting: file) { _ in
                Button("好", role: .cancel) { file = nil }
            } message: { saved in
                Text(saved.lastPathComponent + "\n已保存到“" + saved.deletingLastPathComponent().lastPathComponent + "”文件夹，可前往“文件”App 查看。")
            }
        }
    }
}

extension View {
    func downloadCompletionNotice(_ file: Binding<URL?>) -> some View {
        modifier(DownloadCompletionNotice(file: file))
    }
}

#if DEBUG
/// Exercises the production completion presenter without networking or writing user files.
struct DownloadCompletionStylePreview: View {
    @State private var saved: URL?
    var body: some View {
        NavigationStack {
            List {
                Button("模拟 ZIP 保存完成") {
                    saved = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/fixture/RepoPocket/my-python.zip")
                }.softGroupedRow(top: true, bottom: true)
            }.navigationTitle("下载提示预览")
                .downloadCompletionNotice($saved)
        }
    }
}
#endif
