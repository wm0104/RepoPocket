import SwiftUI

/// Compact system sheet: native dismissal, scrollable notes, and explicit user-controlled install.
struct StartupUpdateCard: View {
    @ObservedObject var api: GitHub
    @ObservedObject var checker: UpdateChecker
    let release: AppUpdateRelease
    let showUpdateSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmInstall = false
    @State private var opening = false
    @State private var requestID = UUID()
    @State private var failure = ""
    @AppStorage("RepoPocket.update.trollStoreLinkAcknowledged") private var acknowledged = false

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var canInstall: Bool {
        guard let ipa = release.ipaURL else { return false }
        return TrollStoreInstallRules.installURL(for: ipa) != nil
    }
    private var notes: String {
        let text = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "暂无发布说明" : String(text.prefix(16_384))
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title2.weight(.medium))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现新版本").font(.title3.weight(.semibold))
                    Text("RepoPocket " + release.displayVersionWithBuild + " · 当前 " + currentVersion)
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2.weight(.medium)).foregroundColor(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("关闭更新提示")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("更新内容").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: notes).font(.subheadline).textSelection(.enabled)
                        if !failure.isEmpty {
                            Text(failure).font(.caption).foregroundColor(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The footer does not scroll; the two buttons have separate >=44pt hit regions.
            VStack(spacing: 6) {
                Text("跳转TrollStore安装需启用 URL Scheme")
                    .font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canInstall && failure.isEmpty {
                    Button(action: requestInstall) {
                        HStack(spacing: 8) {
                            if opening { ProgressView().tint(.white) }
                            Text("TrollStore 安装").font(.body.weight(.semibold))
                        }.frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundColor(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .disabled(opening || checker.checking || checker.downloading || !api.isCurrentSession)
                } else {
                    Button(action: updateSettings) {
                        Text("前往应用更新").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundColor(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                Button(action: close) {
                    Text("暂不更新").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
        // System adds the bottom safe-area inset; approximately 330pt on iPhone.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(300)])
        .presentationDragIndicator(.visible)
        .alert("使用 TrollStore 更新", isPresented: $confirmInstall) {
            Button("取消", role: .cancel) {}
            Button("继续") { acknowledged = true; openInstall() }
        } message: {
            Text("请先在 TrollStore 设置中启用 URL Scheme。继续后将跳转到 TrollStore，由它处理下载和安装；若打开放大器或无法打开，可在设置的应用更新中下载并分享 IPA。")
        }
        .onDisappear { requestID = UUID(); opening = false; confirmInstall = false }
    }
    private func close() {
        requestID = UUID()
        checker.skipAndDismissStartupRelease(accountID: api.accountID)
        dismiss()
    }
    private func updateSettings() {
        close()
        showUpdateSettings()
    }
    private func requestInstall() {
        guard api.isCurrentSession, !opening, !checker.checking, !checker.downloading, canInstall else { return }
        if acknowledged { openInstall() } else { confirmInstall = true }
    }
    private func openInstall() {
        guard api.isCurrentSession, !opening, !checker.checking, !checker.downloading,
              let ipa = release.ipaURL, checker.release?.tag_name == release.tag_name,
              checker.release?.ipaURL == ipa else { return }
        let session = AccountStore.generation
        let id = UUID(); requestID = id; opening = true
        TrollStoreInstaller.open(ipaURL: ipa) { opened in
            guard requestID == id else { return }
            opening = false
            guard session == AccountStore.generation, api.isCurrentSession,
                  checker.release?.tag_name == release.tag_name, checker.release?.ipaURL == ipa else { return }
            if opened {
                checker.message = "已请求打开 TrollStore，请在其中确认下载和安装结果。"
                close()
            } else {
                failure = "无法打开 TrollStore。请启用 URL Scheme，或前往应用更新下载后分享安装。"
            }
        }
    }
}
