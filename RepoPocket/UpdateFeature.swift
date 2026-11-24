import SwiftUI
import UIKit
import ZIPFoundation

@MainActor final class UpdateChecker: ObservableObject {
    @Published var checking = false
    @Published var message = ""
    @Published var release: AppUpdateRelease?
    @Published var downloaded: URL?
    private(set) var downloadedBookmark: Data?
    @Published var downloading = false
    @Published var progress: ReleaseDownloadProgress?
    @Published var downloadStage: String?
    var sharing = false
    private var finalization: Task<Void, Never>?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var delegate: UpdateDownloadDelegate?
    private var generation = UUID()
    private var noticeTask: Task<Void, Never>?
    private var entered = false
    private var autoRules = AppUpdateSessionRules()
    private let accountGeneration = AccountStore.generation
    var hasUpdate: Bool { release != nil }
    /// Called on launch and whenever the app returns to the foreground. Each entry may attempt
    /// once; the per-account timestamp keeps the network check to one per `cooldown`.
    func appEntryCheck(api: GitHub) async {
        if !AppUpdateSessionRules.isUpdateProbe(installedVersion().0) { autoRules.beginEntry() }
        await automaticCheck(api: api)
    }
    func automaticCheck(api: GitHub) async {
        guard api.canCheckOfficialUpdate, api.isCurrentSession, !checking, !downloading else { return }
        let key = "RepoPocket.update.lastCheck." + api.accountID
        let now = Date()
        let probe = AppUpdateSessionRules.isUpdateProbe(installedVersion().0)
        let last = probe ? nil : UserDefaults.standard.object(forKey: key) as? Date
        guard autoRules.claim(now: now, last: last) else { return }
        // A probe must neither inherit nor reset the official app's per-account cooldown.
        if !probe { UserDefaults.standard.set(now, forKey: key) }
        await check(api: api, automatic: true)
    }
    private let noticeSleep: (UInt64) async throws -> Void
    private let installedVersion: () -> (String, String)
    init(noticeSleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         installedVersion: @escaping () -> (String, String) = {
             (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
         }) {
        self.noticeSleep = noticeSleep
        self.installedVersion = installedVersion
    }
    // Page entry is local-only. Release metadata is fetched only by the check button.
    func enterPage() {
        guard !entered else { return }
        entered = true
    }
    private func clearNotice() {
        noticeTask?.cancel(); noticeTask = nil; message = ""
    }
    private func showTransient(_ text: String, duration: UInt64 = UpdateNoticeRules.failureNanoseconds) {
        clearNotice(); message = text
        let token = generation
        let sleep = noticeSleep
        noticeTask = Task { @MainActor [weak self] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token, !self.downloading else { return }
            self.message = ""; self.noticeTask = nil
        }
    }
    func leavePage() {
        generation = UUID(); clearNotice(); checking = false; entered = false
        // Leaving settings cancels the transfer and invalidates any late check/validation result.
        finalization?.cancel(); finalization = nil
        downloadTask?.cancel(); downloadSession?.invalidateAndCancel()
        downloadTask = nil; downloadSession = nil; delegate = nil
        downloading = false; progress = nil; downloadStage = nil
        // Persisted user downloads survive leaving settings.
        downloaded = nil; downloadedBookmark = nil
    }
    func check(api: GitHub, automatic: Bool = false) async {
        guard !checking, !downloading else { return }
        guard api.canCheckOfficialUpdate else { showTransient("请重新打开 App", duration: UpdateNoticeRules.latestNanoseconds); return }
        generation = UUID(); let token = generation
        clearNotice(); checking = true; downloaded = nil; downloadedBookmark = nil
        defer { if generation == token { checking = false } }
        do {
            let data = try await api.officialAppUpdateData()
            guard generation == token, accountGeneration == AccountStore.generation, api.isCurrentSession else { return }
            let value = try JSONDecoder().decode(AppUpdateRelease.self, from: data)
            guard value.html_url.scheme == "https", value.html_url.host == "github.com", value.html_url.path.hasPrefix("/wm0104/RepoPocket/releases/") else { throw AppError(text: "发布页地址不可信。") }
            let (local, build) = installedVersion()
            if try AppUpdateRules.isNewer(value, local: local, localBuild: build) {
                release = value
                message = ""
            } else {
                release = nil
                if !automatic { showTransient("已是最新版本", duration: UpdateNoticeRules.latestNanoseconds) }
            }
        } catch { if generation == token, accountGeneration == AccountStore.generation, !automatic { showTransient(AppUpdateRules.conciseCheckError(error)) } }
    }
    func cancelDownload() {
        generation = UUID(); clearNotice()
        finalization?.cancel(); finalization = nil
        downloadTask?.cancel(); downloadSession?.invalidateAndCancel()
        downloadTask = nil; downloadSession = nil; delegate = nil
        downloading = false; progress = nil; downloadStage = nil; message = "已取消下载。"
    }
    func download() {
        guard !downloading, let release, let source = release.ipaURL else { showTransient("未找到唯一可信的 RepoPocket IPA 附件，请查看发布页。"); return }
        generation = UUID(); let token = generation; let accountSession = AccountStore.generation; clearNotice()
        DownloadStore.shared.begin()
        downloading = true; progress = nil; downloadStage = nil; downloaded = nil; downloadedBookmark = nil; message = "正在下载到本机，完成后校验 IPA。"
        let handler = UpdateDownloadDelegate(progress: { [weak self] value in
            Task { @MainActor in
                guard let self, self.generation == token, accountSession == AccountStore.generation,
                      self.accountGeneration == accountSession, self.downloading, self.downloadStage == nil else { return }
                self.progress = value
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == token, accountSession == AccountStore.generation,
                      self.accountGeneration == accountSession else {
                    if case .success(let file) = result { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                    DownloadStore.shared.end()
                    return
                }
                self.finalization = Task {
                    defer {
                        DownloadStore.shared.end()
                        if self.generation == token {
                            self.downloading = false
                            self.downloadTask = nil
                            self.downloadSession?.finishTasksAndInvalidate()
                            self.downloadSession = nil
                            self.delegate = nil
                            self.finalization = nil
                        }
                    }
                    do {
                        let file = try result.get()
                        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                        try Task.checkCancellation()
                        self.downloadStage = "正在校验 IPA…"
                        self.message = ""
                        try await UpdatePackageVerification.verify(file, source: source, release: release)
                        try Task.checkCancellation()
                        guard self.generation == token, accountSession == AccountStore.generation else { throw CancellationError() }
                        self.downloadStage = "正在保存…"
                        let saved = try await DownloadStore.shared.persist(file, session: accountSession)
                        guard self.generation == token, accountSession == AccountStore.generation else { throw CancellationError() }
                        self.message = ""
                        self.downloadedBookmark = DownloadStore.shared.shareBookmark(for: saved)
                        self.downloaded = saved
                        AppFeedback.show("下载完成", session: accountSession)
                    } catch {
                        if self.generation == token {
                            self.message = error is CancellationError || (error as? URLError)?.code == .cancelled
                                ? "已取消下载。" : "下载/校验失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
        })
        delegate = handler
        let config = URLSessionConfiguration.ephemeral; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: handler, delegateQueue: nil)
        downloadSession = session; downloadTask = session.downloadTask(with: source); downloadTask?.resume()
    }

}
private enum UpdatePackageVerification {
    static func verify(_ file: URL, source: URL, release: AppUpdateRelease) async throws {
        let asset = try release.checksumAsset(for: source)
        let (bytes, response) = try await URLSession.shared.bytes(from: asset.browser_download_url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError(text: "官方 SHA256 附件下载失败。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 64 * 1024 else { throw AppError(text: "官方 SHA256 附件过大。") }
            data.append(byte)
        }
        let expected = try AppUpdateRules.checksum(data, ipaName: source.lastPathComponent, manifest: asset.name == "SHA256SUMS")
        try Task.checkCancellation()
        guard try LocalStore.snapshotFileSHA256(file) == expected else {
            throw AppError(text: "IPA SHA256 与官方附件不符，已阻止安装。")
        }
        let archive = try Archive(url: file, accessMode: .read)
        var foundInfoPlist = false
        for entry in archive {
            try Task.checkCancellation()
            if entry.path.hasPrefix("Payload/"), entry.path.hasSuffix(".app/Info.plist") { foundInfoPlist = true }
            let crc = try archive.extract(entry, consumer: { _ in try Task.checkCancellation() })
            guard crc == entry.checksum else { throw AppError(text: "IPA ZIP CRC 校验失败。") }
        }
        guard foundInfoPlist else { throw AppError(text: "下载内容不是有效的 IPA（缺少 Payload App）。") }
    }
}
final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (ReleaseDownloadProgress) -> Void
    let completion: (Result<URL, Error>) -> Void
    private var result: Result<URL, Error>?
    private lazy var transfer = ReleaseAssetDownloadDelegate(update: progress)
    init(progress: @escaping (ReleaseDownloadProgress) -> Void, completion: @escaping (Result<URL, Error>) -> Void) { self.progress = progress; self.completion = completion }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        transfer.receive(ReleaseDownloadProgress(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError(text: "IPA 下载 HTTP 状态无效。") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RepoPocket-update-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("RepoPocket.ipa")
            try FileManager.default.moveItem(at: location, to: file); result = .success(file)
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer.stop()
        if error != nil, case .success(let file)? = result { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        completion(error.map { .failure($0) } ?? result ?? .failure(AppError(text: "下载未生成文件。")))
    }
}
struct AppUpdateSection: View {
    @ObservedObject var api: GitHub
    @ObservedObject var checker: UpdateChecker
    var connected = false
    @State private var share: SharedFile?
    @State private var showingOfficialReleases = false
    @State private var authorizing = false
    @State private var expanded = false
    @State private var openingTrollStore = false
    @State private var confirmTrollStore = false
    @State private var trollStoreRequestID = UUID()
    @AppStorage("RepoPocket.update.trollStoreLinkAcknowledged") private var trollStoreLinkAcknowledged = false
    var body: some View {
        Group {
            HStack {
                Text("应用更新")
                Spacer()
                // The available version sits on the right; the 设置 tab dot is the notification.
                if let release = checker.release {
                    Text(release.availableVersionText).font(.subheadline).foregroundColor(.secondary)
                }
                Menu {
                    Button("官方发行版页") {
                        DispatchQueue.main.async { showingOfficialReleases = true }
                    }
                    if let release = checker.release, let ipa = release.ipaURL {
                        Button("复制可信下载链接") { UIPasteboard.general.url = ipa; AppFeedback.show("下载链接已复制", api: api) }
                    }
                    if checker.downloaded != nil { Button("重新下载") { authorizeDownload() }.disabled(authorizing || checker.checking || checker.downloading || openingTrollStore) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("应用更新选项").accessibilityIdentifier("settings-update-options")
            }.softGroupedRow(top: !connected, cardVerticalPadding: 0)
            .sheet(isPresented: $showingOfficialReleases) {
                ContainedWebPage(url: URL(string: "https://github.com/wm0104/RepoPocket/releases")!, onClose: { showingOfficialReleases = false }).ignoresSafeArea()
            }
            .sheet(item: $share, onDismiss: { checker.sharing = false }) { ShareSheet(url: $0.url, bookmark: $0.bookmark) }
            .alert("使用 TrollStore 更新", isPresented: $confirmTrollStore) {
                Button("取消", role: .cancel) {}
                Button("继续") { trollStoreLinkAcknowledged = true; openTrollStoreInstall() }
            } message: {
                Text("请先在 TrollStore 设置中启用 URL Scheme，并按它的提示应用设置。TrollStore 将下载官方 IPA 并处理安装，此方式不经过 RepoPocket 的本地 SHA256 校验。未安装 TrollStore 或未启用协议时可能打开放大器；也可取消后使用下载更新和分享安装。")
            }.onDisappear { confirmTrollStore = false; openingTrollStore = false; trollStoreRequestID = UUID() }
            if !checker.message.isEmpty { Text(checker.message).font(.caption).textSelection(.enabled).softGroupedRow() }
            if checker.downloading {
                DownloadProgressRow(name: "RepoPocket.ipa", progress: checker.downloadStage == nil ? checker.progress : nil,
                                    status: checker.downloadStage).softGroupedRow()
                Button("取消下载", role: .cancel) { checker.cancelDownload() }.softGroupedRow()
            } else if let file = checker.downloaded {
                Button("分享 IPA 安装") { checker.sharing = true; share = SharedFile(url: file, bookmark: checker.downloadedBookmark) }.softGroupedRow()
            } else if let release = checker.release {
                Text("新版本 " + release.displayVersionWithBuild).softGroupedRow()
                DisclosureGroup("发布说明", isExpanded: $expanded) {
                    Text(String((release.body ?? "暂无发布说明").prefix(16_384))).font(.caption)
                        .softGroupedRow()
                }.softGroupedRow()
                if release.ipaURL != nil {
                    if let ipa = release.ipaURL, TrollStoreInstallRules.installURL(for: ipa) != nil {
                        Button("TrollStore 更新安装") { requestTrollStoreInstall() }.disabled(checker.checking || checker.downloading || authorizing || openingTrollStore).softGroupedRow()
                    }
                    Button("下载更新") { authorizeDownload() }.disabled(checker.checking || authorizing || checker.downloading || openingTrollStore).softGroupedRow()
                } else {
                    Text("暂无可安装的 IPA，请到发行版页下载。").font(.caption).softGroupedRow()
                    InAppLinkButton(url: release.html_url, api: nil) { Text("前往下载") }.softGroupedRow()
                }
            } else {
                Button(checker.checking ? "检查中…" : "检查更新") { Task { await checker.check(api: api) } }.disabled(checker.checking || checker.downloading).softGroupedRow()
            }
        }
    }
    private func requestTrollStoreInstall() {
        guard api.isCurrentSession, !checker.checking, !checker.downloading, !authorizing, !openingTrollStore,
              let ipa = checker.release?.ipaURL, TrollStoreInstallRules.installURL(for: ipa) != nil else { return }
        if trollStoreLinkAcknowledged {
            openTrollStoreInstall()
        } else { confirmTrollStore = true }
    }
    private func openTrollStoreInstall() {
        guard api.isCurrentSession, !checker.checking, !checker.downloading, !authorizing, !openingTrollStore,
              let release = checker.release, let ipa = release.ipaURL else { return }
        let session = AccountStore.generation
        let tag = release.tag_name
        let requestID = UUID(); trollStoreRequestID = requestID
        openingTrollStore = true
        TrollStoreInstaller.open(ipaURL: ipa) { opened in
            guard trollStoreRequestID == requestID else { return }
            openingTrollStore = false
            guard session == AccountStore.generation, api.isCurrentSession,
                  checker.release?.tag_name == tag, checker.release?.ipaURL == ipa else { return }
            checker.message = opened
                ? "已请求打开 TrollStore，请在其中查看下载和安装结果。若打开放大器，请启用 TrollStore 的 URL Scheme，或使用下载更新。"
                : "无法打开链接安装，请启用 TrollStore 的 URL Scheme，或使用下载更新后分享安装。"
        }
    }
    private func authorizeDownload() {
        guard api.isCurrentSession, !authorizing, !checker.checking, !checker.downloading, !openingTrollStore else { return }; authorizing = true
        Task { @MainActor in
            defer { authorizing = false }
            do {
                let session = AccountStore.generation
                try await DownloadStore.shared.requireAuthorization()
                guard session == AccountStore.generation, api.isCurrentSession else { return }
                checker.download()
            } catch { if !(error is CancellationError) { checker.message = error.localizedDescription } }
        }
    }

}
