import SwiftUI
import UIKit
import ZIPFoundation

@MainActor final class UpdateChecker: ObservableObject {
    @Published var checking = false
    @Published var message = ""
    @Published var release: AppUpdateRelease?
    @Published private(set) var startupRelease: AppUpdateRelease?
    func dismissStartupUpdate() { startupRelease = nil }
    /// Dismissing the startup card by button, close, or swipe remembers the version so the
    /// same release is not offered again on every launch. Manual checks still show it.
    func skipAndDismissStartupRelease(accountID: String) {
        if let version = startupRelease?.tag_name {
            UserDefaults.standard.set(version, forKey: AppUpdateRules.skippedKey(accountID))
        }
        dismissStartupUpdate()
    }
    private var startupPromptOffered: Bool {
        get { AppUpdateSessionRules.startupPromptOffered }
        set { AppUpdateSessionRules.startupPromptOffered = newValue }
    }
    @Published var downloaded: URL?
    @Published var downloading = false
    @Published var progress: Double = 0
    var sharing = false
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var delegate: UpdateDownloadDelegate?
    private var generation = UUID()
    private var noticeTask: Task<Void, Never>?
    private var entered = false
    private var autoRules = AppUpdateSessionRules()
    private let accountGeneration = AccountStore.generation
    var hasUpdate: Bool { release != nil }
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
        downloadTask?.cancel(); downloadSession?.invalidateAndCancel()
        downloadTask = nil; downloadSession = nil; delegate = nil
        downloading = false; progress = 0
        // Persisted user downloads survive leaving settings.
        downloaded = nil
    }
    func check(api: GitHub, automatic: Bool = false) async {
        guard !checking, !downloading else { return }
        guard api.canCheckOfficialUpdate else { showTransient("当前会话不可用，请重新打开 App", duration: UpdateNoticeRules.latestNanoseconds); return }
        generation = UUID(); let token = generation
        clearNotice(); checking = true; downloaded = nil
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
                if automatic, !startupPromptOffered {
                    startupPromptOffered = true
                    let skipped = UserDefaults.standard.string(forKey: AppUpdateRules.skippedKey(api.accountID))
                    if AppUpdateRules.shouldOfferStartupPrompt(version: value.tag_name, skipped: skipped) {
                        startupRelease = value
                    }
                }
            } else {
                release = nil; startupRelease = nil
                if !automatic { showTransient("已是最新版本", duration: UpdateNoticeRules.latestNanoseconds) }
            }
        } catch { if generation == token, accountGeneration == AccountStore.generation, !automatic { showTransient(AppUpdateRules.conciseCheckError(error)) } }
    }
    func ignore() { generation = UUID(); release = nil; startupRelease = nil; showTransient("本次不更新。") }
    func cancelDownload() {
        generation = UUID(); clearNotice()
        downloadTask?.cancel(); downloadSession?.invalidateAndCancel()
        downloadTask = nil; downloadSession = nil; delegate = nil
        downloading = false; progress = 0; message = "已取消下载。"
    }
    func download() {
        guard !downloading, let release, let source = release.ipaURL else { showTransient("未找到唯一可信的 RepoPocket IPA 附件，请查看发布页。"); return }
        generation = UUID(); let token = generation; let accountSession = AccountStore.generation; clearNotice()
        DownloadStore.shared.begin()
        downloading = true; progress = 0; downloaded = nil; message = "正在下载到本机，完成后校验 IPA。"
        let handler = UpdateDownloadDelegate(progress: { [weak self] value in Task { @MainActor in guard let self, self.generation == token, self.downloading else { return }; self.progress = value } }, completion: { [weak self] result in
            Task { @MainActor in
                defer { DownloadStore.shared.end() }
                guard let self, self.generation == token else {
                    if case .success(let file) = result { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }; return
                }
                defer { if self.generation == token { self.downloading = false; self.downloadTask = nil; self.downloadSession?.finishTasksAndInvalidate(); self.downloadSession = nil; self.delegate = nil } }
                do {
                    let file = try result.get()
                    do {
                        let archive = try Archive(url: file, accessMode: .read)
                        guard archive.contains(where: { $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist") }) else { throw AppError(text: "下载内容不是有效的 IPA（缺少 Payload App）。") }
                        // Exercise CRC validation without extracting untrusted paths to disk.
                        for entry in archive {
                            let crc = try archive.extract(entry, consumer: { _ in })
                            guard crc == entry.checksum else { throw AppError(text: "IPA ZIP CRC 校验失败。") }
                        }
                        let checksumName = source.lastPathComponent + ".sha256"
                        if let checksum = release.assets.first(where: { $0.name == checksumName }) {
                            guard checksum.browser_download_url.scheme == "https", checksum.browser_download_url.host == "github.com", checksum.browser_download_url.path.hasPrefix("/wm0104/RepoPocket/releases/download/") else { throw AppError(text: "SHA256 附件地址不可信。") }
                            let (data, response) = try await URLSession.shared.data(from: checksum.browser_download_url)
                            guard self.generation == token else { throw CancellationError() }
                            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8), let expected = text.split(whereSeparator: { $0.isWhitespace }).first, expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { throw AppError(text: "官方 SHA256 附件无效或下载失败。") }
                            guard try LocalStore.snapshotFileSHA256(file) == expected.lowercased() else { throw AppError(text: "IPA SHA256 与官方附件不符，已阻止安装。") }
                            self.message = "下载完成，请选择应用安装"
                        } else { self.message = "下载完成，请选择应用安装" }
                        guard self.generation == token, accountSession == AccountStore.generation else { throw CancellationError() }
                        let saved = try await DownloadStore.shared.persist(file, session: accountSession)
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        self.message = "已保存到 " + DownloadStore.shared.label + "，请选择应用安装"
                        self.downloaded = saved
                    } catch { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); throw error }
                } catch { if self.generation == token { self.message = (error as? URLError)?.code == .cancelled ? "已取消下载。" : "下载/校验失败：\(error.localizedDescription)" } }
            }
        })
        delegate = handler
        let config = URLSessionConfiguration.ephemeral; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: handler, delegateQueue: nil)
        downloadSession = session; downloadTask = session.downloadTask(with: source); downloadTask?.resume()
    }

}
final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    let completion: (Result<URL, Error>) -> Void
    private var result: Result<URL, Error>?
    init(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) { self.progress = progress; self.completion = completion }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError(text: "IPA 下载 HTTP 状态无效。") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RepoPocket-update-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("RepoPocket.ipa")
            try FileManager.default.moveItem(at: location, to: file); result = .success(file)
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { completion(error.map { .failure($0) } ?? result ?? .failure(AppError(text: "下载未生成文件。"))) }
}
struct AppUpdateSection: View {
    @ObservedObject var api: GitHub
    @ObservedObject var checker: UpdateChecker
    @State private var share: SharedFile?
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
                Menu {
                    Link("官方发行版页", destination: URL(string: "https://github.com/wm0104/RepoPocket/releases")!)
                    if let release = checker.release, let ipa = release.ipaURL {
                        Button("复制可信下载链接") { UIPasteboard.general.url = ipa }
                    }
                    if checker.downloaded != nil { Button("重新下载") { authorizeDownload() }.disabled(authorizing || checker.checking || checker.downloading || openingTrollStore) }
                } label: { Image(systemName: "ellipsis") }
            }.softGroupedRow(top: true)
            if !checker.message.isEmpty { Text(checker.message).font(.caption).textSelection(.enabled).softGroupedRow() }
            if checker.downloading {
                ProgressView(value: checker.progress).softGroupedRow()
                Button("取消下载", role: .cancel) { checker.cancelDownload() }.softGroupedRow()
            } else if let file = checker.downloaded {
                Button("分享 IPA 安装") { checker.sharing = true; share = SharedFile(url: file) }.softGroupedRow()
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
                    Text("未找到唯一可信 IPA，请前往官方发行版下载。").font(.caption).softGroupedRow()
                    Link("前往下载", destination: release.html_url).softGroupedRow()
                }
            } else {
                Button(checker.checking ? "检查中…" : "检查更新") { Task { await checker.check(api: api) } }.disabled(checker.checking || checker.downloading).softGroupedRow()
            }
        }.sheet(item: $share, onDismiss: { checker.sharing = false }) { ShareSheet(url: $0.url) }
        .alert("使用 TrollStore 更新", isPresented: $confirmTrollStore) {
            Button("取消", role: .cancel) {}
            Button("继续") { trollStoreLinkAcknowledged = true; openTrollStoreInstall() }
        } message: {
            Text("请先在 TrollStore 设置中启用 URL Scheme，并按它的提示应用设置。TrollStore 将下载官方 IPA 并处理安装，此方式不经过 RepoPocket 的本地 SHA256 校验。未安装 TrollStore 或未启用协议时可能打开放大器；也可取消后使用下载更新和分享安装。")
        }.onDisappear { confirmTrollStore = false; openingTrollStore = false; trollStoreRequestID = UUID() }
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
