import SwiftUI

struct CommitMediaDiffView: View {
    @ObservedObject var api: GitHub
    let repo: String
    let commitSHA: String
    let parents: [DesktopCommit.Parent]?
    let file: DesktopCommit.File

    private enum Side: Hashable { case before, after }
    @State private var side: Side = .after
    @State private var versions: CommitFileRules.Versions?
    @State private var accountChanged = false
    private var valid: Bool { !accountChanged && api.isCurrentSession }
    private var mergeParent: String? { CommitFileRules.mergeParent(commitSHA: commitSHA, parents: parents) }

    var body: some View {
        VStack(spacing: 8) {
            if !valid {
                Text("账号已切换，请返回重新打开。").padding()
            } else {
                if let mergeParent {
                    Text("第一父比较基准：\(mergeParent)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.horizontal, 8)
                }
                if let versions {
                    if versions.before != nil && versions.after != nil {
                        Picker("历史版本", selection: $side) {
                            Text("修改前").tag(Side.before)
                            Text("修改后").tag(Side.after)
                        }.pickerStyle(.segmented).padding(.horizontal, 8)
                            .accessibilityIdentifier("commit-media-side-picker")
                    } else if versions.before != nil {
                        Text("修改前").font(.headline).accessibilityIdentifier("commit-media-before-only")
                    } else if versions.after != nil {
                        Text("修改后").font(.headline).accessibilityIdentifier("commit-media-after-only")
                    }
                    if let notice = versions.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    if let version = side == .before ? versions.before : versions.after {
                        Text("\(version.path) · \(version.sha.prefix(7))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.horizontal, 8).accessibilityIdentifier("commit-media-version")
                        CommitHistoryPreviewContent(api: api, repo: repo, version: version)
                            .id(side)
                    }
                } else {
                    ProgressView("正在核实比较版本…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle((file.filename as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: valid) { await loadVersions() }
        .onReceive(NotificationCenter.default.publisher(for: .githubAccountChanged)) { _ in
            if !api.isCurrentSession { accountChanged = true; versions = nil }
        }
    }

    private func loadVersions() async {
        guard valid, versions == nil else { return }
        var comparison: CommitMediaComparison?
        if let mergeParent {
            do {
                comparison = try await api.commitMediaComparison(repo, parentSHA: mergeParent, commitSHA: commitSHA)
            } catch {
                guard !RefreshFailure.isCancellation(error) else { return }
                // A failed compare proves nothing; only the known after side may remain.
            }
        }
        do { try Task.checkCancellation() } catch { return }
        guard valid else { return }
        let result = CommitFileRules.versions(commitSHA: commitSHA, parents: parents, file: file, comparison: comparison)
        side = result.after == nil ? .before : .after
        versions = result
    }
}
