#if DEBUG
import SwiftUI

/// Exercises the real release screen/controller without networking or user files.
struct ReleaseDownloadStylePreview: View {
    @State private var state: ReleaseScreenState?
    @State private var error = ""
    var body: some View {
        Group {
            if let state { NavigationStack { ReleaseDetailView(state: state, id: 7) } }
            else if !error.isEmpty { Text(error) }
            else { ProgressView("准备下载测试") }
        }.task {
            guard state == nil, error.isEmpty else { return }
            do {
                let id = "release-preview"
                try CredentialStore.save("fixture-release", account: id)
                try AccountStore.record(.init(id: id, login: "fixture-owner", avatarURL: nil)); AccountStore.activate(id)
                let api = GitHub(); api.login = "fixture-owner"
                let value = ReleaseScreenState(api: api, repo: "fixture-owner/sample", downloader: PreviewAssetDownloader())
                value.release = ManagedRelease(id: 7, tag_name: "v1.1.0", name: "RepoPocket 1.1.0", draft: false, prerelease: false, created_at: "2026-10-19T00:00:00Z", published_at: nil, updated_at: "2026-10-19T00:00:00Z", body: "Download preview")
                value.assets = (1...3).map { Asset(id: $0, name: "sample-\($0).ipa", size: 5_000_000, browser_download_url: "https://github.com/fixture-owner/sample/releases/download/v1.1.0/sample-\($0).ipa") }
                value.canWrite = true; state = value
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor private final class PreviewAssetDownloader: ReleaseAssetDownloading {
    var label: String { "测试下载文件夹" }
    private var attempts = 0
    func authorize() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    func begin() {}
    func end() {}
    func download(api: GitHub, repo: String, asset: Asset, update: @escaping (ReleaseDownloadProgress) -> Void) async throws -> URL {
        attempts += 1
        try await Task.sleep(nanoseconds: 300_000_000)
        if ProcessInfo.processInfo.arguments.contains("-release-download-failure"), attempts == 1 { throw AppError(text: "测试连接失败") }
        update(.init(received: 2_000_000, total: 5_000_000))
        try await Task.sleep(nanoseconds: 5_000_000_000)
        update(.init(received: 5_000_000, total: 5_000_000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(asset.name); try Data([1, 2, 3]).write(to: file); return file
    }
    func persist(_ file: URL, generation: UUID) async throws { try await Task.sleep(nanoseconds: 300_000_000) }
}
#endif
