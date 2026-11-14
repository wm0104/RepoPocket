import SwiftUI

struct ReleaseAssetDownloadStatusView: View {
    let download: ReleaseAssetDownload
    let cancel: () -> Void
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if download.active && (download.stage != .downloading || download.progress?.fraction == nil) { ProgressView() }
                Image(systemName: download.stage == .completed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(download.stage == .completed ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)
                Text(download.title).font(.caption).foregroundStyle(download.stage == .failed ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("release-download-status-\(download.assetID)")
                if download.cancellable {
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel("取消下载")
                } else if download.stage == .failed || download.stage == .cancelled {
                    Button("重试", action: retry).buttonStyle(.borderless).frame(minHeight: 44)
                        .accessibilityIdentifier("release-download-retry-\(download.assetID)")
                }
            }
            if download.stage == .downloading, let value = download.progress?.fraction { ProgressView(value: value) }
            if download.active { Text("请保持前台，勿锁屏。").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.bottom, 5)
    }
}
