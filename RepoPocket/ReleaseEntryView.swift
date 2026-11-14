import SwiftUI

// All entry points use the same complete form; no repository-only intermediary.
struct ReleaseEntryView: View {
    @ObservedObject var api: GitHub
    var initialRepo = ""
    var initialBranch = ""
    var initialFiles: [URL] = []
    var body: some View {
        ReleaseEditorView(api: api, repo: initialRepo, original: nil, initialBranch: initialBranch,
                          initialFiles: initialFiles, allowsRepositorySelection: true)
    }
}
