#if DEBUG
import SwiftUI

/// The production list and disk model, with local fixture files and no network requests.
struct DownloadCenterStylePreview: View {
    @State private var api: GitHub?
    @State private var store: DownloadStore?
    @State private var error = ""
    @State private var attempted = false
    @State private var audit = ""
    var body: some View {
        VStack(spacing: 0) {
            if let api, let store {
                AppNavigationStack { DownloadCenterView(api: api, store: store) }
                HStack {
                    Button("检查副本") {
                        let files = (try? ShareInboxStore.live().items()) ?? []
                        audit = files.contains { $0.name == "插件.deb" } ? "待上传副本存在" : "无待上传副本"
                    }
                    Button("切换账号") { AccountStore.activate("900002") }
                    Text(audit).accessibilityIdentifier("download-audit")
                }.font(.caption2).padding(4)
            } else if !error.isEmpty { Text(error) }
            else { ProgressView() }
        }.task {
            guard !attempted else { return }; attempted = true
            do {
                let account = "900001"
                try AccountStore.record(.init(id: account, login: "download-fixture", avatarURL: nil))
                try AccountStore.record(.init(id: "900002", login: "other-fixture", avatarURL: nil))
                try CredentialStore.save("download-fixture-token", account: account)
                AccountStore.activate(account)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCenterPreview", isDirectory: true)
                if !ProcessInfo.processInfo.arguments.contains("-download-keep-history"), FileManager.default.fileExists(atPath: root.path) {
                    try DownloadRules.rejectSymlinks(root)
                    try FileManager.default.removeItem(at: root)
                }
                let history = DownloadHistory(root: root, accountID: account)
                let existing = try history.load()
                if existing.isEmpty && !ProcessInfo.processInfo.arguments.contains("-download-keep-history") {
                    var records: [DownloadRecord] = []
                    for (index, name) in ["插件.deb", "应用.ipa", "应用.tipa"].enumerated() {
                        let source = root.appendingPathComponent(name)
                        try Data("local fixture".utf8).write(to: source)
                        let saved = try DownloadRules.save(source, parent: history.folder, valid: { true }, fingerprint: LocalStore.snapshotFileSHA256)
                        records.append(.init(id: UUID(), source: .releaseAsset(repo: "fixture/download", id: index + 1, name: name),
                            created: Date(), state: .completed, fileName: saved.lastPathComponent))
                    }
                    records.append(.init(id: UUID(), source: .archive(repo: "fixture/source", ref: "test"), created: Date(), state: .downloading))
                    try history.save(records)
                }
                store = DownloadStore(root: root)
                api = GitHub()
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
