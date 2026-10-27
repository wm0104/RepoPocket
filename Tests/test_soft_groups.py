from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

ui = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
workspace = Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
upload = Path(REPO_ROOT, 'RepoPocket/UploadView.swift').read_text()
detail = Path(REPO_ROOT, 'RepoPocket/DesktopViews.swift').read_text()
style = Path(REPO_ROOT, 'RepoPocket/WorkspaceSelectionUI.swift').read_text()
card = Path(REPO_ROOT, 'RepoPocket/RepositoryUI.swift').read_text().split('struct RepositoryCard:')[1].split('struct LoadingRows:')[0]
assert '.frame(maxWidth: .infinity, alignment: .leading)' in card
assert 'listRowSeparator(.hidden)' in style
assert '.padding(.leading, separatorInset)' in style
assert '.overlay(alignment: .bottom)' in style
assert 'separatorInset: CGFloat = 20' in style
assert 'if !bottom {' in style
assert 'GitHubAvatar(url: avatarURL, size: 24)' in card
assert 'cornerRadius: radius, style: .continuous' in style and 'let radius: CGFloat = 22' in style
assert 'listRowBackground(' in style and 'SoftGroupShape' in style and '.secondarySystemGroupedBackground' in style
# Only the decoration is clipped; never clip the interactive List or its content.
assert style.count('.clipShape(') == 1
assert '.appearance()' not in style and '.blur(' not in style
for text in [ui, workspace, upload, detail]:
    assert '.softGroupedRow(top: true)' in text
    assert '.softGroupedRow(bottom: true)' in text
section = ui.split('RepositoryHomeLinksSection(api: api', 1)[1].split('.listStyle(.insetGrouped)', 1)[0]
assert 'DisclosureGroup' not in section and 'repositoriesExpanded' not in ui
repoSection = section.split('发现与关注动态', 1)[0]
assert 'softGroupedRow' not in repoSection
# Task-first home: owned/starred repositories come first; community discovery
# stays below them as one standalone rounded row.
assert section.index('发现与关注动态') > section.index('UserConnectionsSection')
assert '.softGroupedRow(top: true, bottom: true)' in section
assert 'refresh()' not in section and 'repos = []' not in section
assert 'NavigationLink("添加 / 更新 GitHub 账号")' in Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
assert 'Section("已保存账号")' not in ui
assert '.sheet(isPresented: $accountPresentation.showing' in ui
assert '.listStyle(.insetGrouped)' in workspace and '.listStyle(.insetGrouped)' in ui
assert '.formStyle(.grouped)' in upload
assert '.swipeActions {' not in workspace and 'pendingDelete = root; confirmDelete = true' in workspace
assert '.contextMenu {' in workspace
assert '.contextMenu' in ui and 'confirmationDialog' in ui
assert 'verticalSizeClass == .compact ? 3 : 7' in card
assert '.lineLimit(descriptionLineLimit)' in card
# Divider regression: screenshot paths must decorate all intermediate rows.
assert 'Section("直接打开仓库")' not in ui
assert '.sheet(isPresented: $showOpen)' in ui
assert 'NavigationLink("浏览")' in ui
assert '.softGroupedRow().softGroupedRow' not in ui + workspace + upload
assert ui.count('top: e.id == entries.first?.id, bottom: e.id == entries.last?.id') == 3
# The file reader is now a full-height code surface; its loading indicator is
# no longer a terminal row inside the old metadata/download Form.
# Import buttons moved into the toolbar Menu (not List rows).
for marker in ['Text(binding.repo + " · " + binding.branch)', 'TextField("提交说明", text: $commitMessage)']:
    row = next(line for line in workspace.splitlines() if marker in line)
    assert '.softGroupedRow()' in row, row
for marker in ['LabeledContent("目录",', 'Text(r.draft ?', 'Text("附件："',
               'Button("公开此 Release")', 'ShareLink("分享下载链接"',
               'Button("检查提交权限")']:
    row = next(line for line in upload.splitlines() if marker in line)
    assert '.softGroupedRow()' in row, row
assert 'bottom: local == nil' in upload
assert 'bottom: !(bytes > 10 * 1024 * 1024 && mode == 0)' in upload
assert 'ReleaseEntryView(api: api, initialRepo: repo, initialBranch: branch)' in upload
assert 'Button("发布") { sharedReleaseEntry = true }' in upload
# Exhaust optional terminal rows: exactly one bottom, never an internal rounded edge.
for has_file in (False, True):
    for oversized in (False, True):
        for mode in (0, 1, 2):
            bottoms = [not has_file]
            if has_file:
                warning = oversized and mode == 0
                bottoms += [False, False, not warning]
                if warning: bottoms += [True]
            assert sum(bottoms) == 1 and bottoms[-1]
for has_release in (False, True):
    bottoms = [not has_release] + ([False, True] if has_release else [])
    assert sum(bottoms) == 1 and bottoms[-1]
# Local workspace groups: the hint always opens the group; only the actual last
# row closes it. Selection and long-press actions remain native List rows.
local = workspace.split('private var localSection: some View {', 1)[1].split('private func workspaceManagement', 1)[0]
assert 'softGroupedRow(top: true, bottom: roots.isEmpty)' in local
assert '.softGroupedRow(bottom: root == roots.last)' in local
assert 'ForEach(roots, id: \\.path)' in local and '.contextMenu {' in local
management = workspace.split('private func workspaceManagement', 1)[1].split('private func bindingSection', 1)[0]
assert 'if let binding { Text(binding.repo + " / " + binding.branch).font(.headline).softGroupedRow(top: true) }' in management
assert 'Menu("工作区…")' in management
assert '.disabled(busy).softGroupedRow(top: binding == nil, bottom: !linked)' in management
assert '.font(.caption).softGroupedRow(bottom: true)' in management
for count in (0, 1, 3):
    edges = [(True, count == 0)] + [(False, index == count - 1) for index in range(count)]
    assert sum(top for top, _ in edges) == 1 and edges[0][0]
    assert sum(bottom for _, bottom in edges) == 1 and edges[-1][1]
for has_binding in (False, True):
    for linked in (False, True):
        edges = ([(True, False)] if has_binding else []) + [(not has_binding, not linked)]
        if linked: edges += [(False, True)]
        assert sum(top for top, _ in edges) == sum(bottom for _, bottom in edges) == 1

# The local changes section ends with one fixed, concise hint rather than an expandable
# disclosure. Keep it as the terminal decorated row so the outer rounded group remains intact.
changes = workspace.split('private var changesSection: some View {', 1)[1].split('private var conflictSheet', 1)[0]
assert 'DisclosureGroup("提交说明与限制")' not in changes
assert '刷新变更。' in changes
assert '.font(.caption).foregroundStyle(.secondary).softGroupedRow(bottom: true)' in changes
assert 'Button("刷新变更") { Task { await scan() } }.disabled(busy).softGroupedRow(bottom: selected.isEmpty)' in changes
for has_selection in (False, True):
    bottoms = [not has_selection] + ([True] if has_selection else [])
    assert sum(bottoms) == 1 and bottoms[-1]
assert '.clipShape(' not in workspace and '.listStyle(.insetGrouped)' in workspace
print('PASS local group boundaries: empty/single/multiple directories, bound/unbound menu, selected/unselected and fixed terminal hint')
print('PASS divider regression: settings, upload, local directory, workspace detail; conditional last-row corners')
print('PASS soft grouped UI contracts: equal-width repositories, 22pt continuous row backgrounds, native lists/swipe deletion, semantic colors and adaptive text')

# Feature-page expansion: explicit native-row contracts plus complete conditional
# edge matrices. No new script: existing workflow registration/count stays exact.
import itertools
import subprocess

def source(name):
    return (REPO_ROOT / 'RepoPocket' / name).read_text()

picker = source('ReleaseBranchPicker.swift')
picker_ui = picker.split('struct ReleaseBranchPicker: View {', 1)[1]
# Restore both expansion interactions from 1.0.1+1: native sibling Form rows
# for branches, and native DisclosureGroup for the advanced SHA target.
assert 'Section {\n            if state.loading' in picker_ui
assert 'VStack(alignment: .leading, spacing: 0)' not in picker_ui
assert 'branchRow' not in picker_ui and '.listRowInsets(EdgeInsets())' not in picker_ui
assert '.buttonStyle(.borderless)' in picker_ui
assert 'minHeight: 44' in picker_ui and '.contentShape(Rectangle())' in picker_ui
assert 'ForEach(visible, id: \\.self)' in picker_ui
assert 'LazyVStack' not in picker_ui
assert 'DisclosureGroup("高级：提交 SHA", isExpanded: $advanced)' in picker_ui
assert picker_ui.count('Section {') == 1
assert '.easeInOut(duration: 0.18)' in picker_ui and 'reduceMotion ? nil' in picker_ui
assert 'animate { expanded.toggle() }' in picker_ui
assert 'animate { expanded = false; advanced = false }' in picker_ui
assert 'animate { advanced.toggle() }' not in picker_ui
assert '.softGroupedRow(top: !state.loading)' in picker_ui
assert 'softGroupedRow(top: false, bottom: false)' in picker_ui
assert 'softGroupedRow(bottom: true)' in picker_ui
assert 'Rectangle().fill(Color(uiColor: .separator))' not in picker_ui
assert '.onDisappear { state.cancel(); ready = false }' in picker_ui

release_entry = upload.split('private var releaseSection: some View {', 1)[1].split('static func inferredTrollVersion', 1)[0]
assert 'releaseExpanded' not in upload
assert '已有发行版 / 继续草稿' not in release_entry
assert 'DisclosureGroup' not in release_entry and 'withAnimation' not in release_entry
assert 'ReleaseManagementDestination(api: api, repo: repo)' in release_entry
assert '.disabled(busy || repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)' in release_entry
assert release_entry.count('.softGroupedRow(bottom: true)') == 1
# Empty/whitespace cannot navigate, other input retains the destination's
# existing parser, repository lookup and permission validation (no input-time I/O).
for value, busy in itertools.product(('', '   ', '\n\t', 'wm0104/RepoPocket',
                                      'https://github.com/wm0104/RepoPocket', 'not-a-repository'),
                                     (False, True)):
    disabled = busy or not value.strip()
    assert disabled == (busy or value in ('', '   ', '\n\t'))
github = source('GitHub.swift')
managed_json = github.split('private func managedJSON<', 1)[1].split('private var managedPresenceCache', 1)[0]
assert 'let canonical = try RepositoryInput.parse(repo)' in managed_json
assert managed_json.index('RepositoryInput.parse(repo)') < managed_json.index('try request(')
assert 'if http.statusCode == 404 { throw ManagedReleaseHTTPError' in managed_json
assert 'try await managedJSON([ReleaseSummary].self, repo: repo' in github
assert 'api.managedRepository(repo)' in source('ReleaseManagementUI.swift')
assert 'ReleaseManagementRules.canWrite' in source('ReleaseManagementUI.swift')

release = source('ReleaseManagementUI.swift')
assert 'bottom: row.id == state.rows.last?.id && !state.more' in release
assert 'top: state.rows.isEmpty && state.busy, bottom: true' in release
detail_ui = release.split('struct ReleaseDetailView: View', 1)[1].split('private func upload', 1)[0]
asset_ui = detail_ui.split('ForEach(state.assets) { asset in', 1)[1].split('if state.assets.isEmpty', 1)[0]
assert 'let isLastAsset = asset.id == state.assets.last?.id && !state.assetMore' in asset_ui
assert asset_ui.count('.softGroupedRow(') == 1  # approved compact attachment row with native actions
assert '.softGroupedRow(top: asset.id == state.assets.first?.id, bottom: isLastAsset)' in asset_ui
assert 'LocalGitFileLabel(' in asset_ui and 'Menu {' in asset_ui
assert 'ReleaseAssetDownloadStatusView(' in asset_ui
assert 'Divider()' not in asset_ui and 'Rectangle().fill' not in asset_ui
assert 'bottom: item.id == attachments.last?.id && !staging' in release
assert 'bottom: markerReady || state.busy' in release
assert 'bottom: state.error.isEmpty && state.valid' in release
assert 'top: !state.busy && state.error.isEmpty, bottom: true' in release
assert 'Divider()' not in detail_ui  # all detail rows use the same full-width separator
assert 'originalKeys, id: \\.self' in source('DebEditorView.swift')
assert 'bottom: key == originalKeys.last' in source('DebEditorView.swift')
assert 'top: original["Name"] == nil && original["Author"] == nil' in source('DebEditorView.swift')
assert 'top: repository.id == filteredRepositories.first?.id' in source('RepositorySections.swift')
assert 'bottom: repository.id == filteredRepositories.last?.id' in source('RepositorySections.swift')
for file in ['AccountManagement.swift', 'DebEditorView.swift', 'DesktopViews.swift',
             'GitWorkspaceView.swift', 'ReleaseEntryView.swift', 'RepositoryDeletionView.swift',
             'RepositorySearchView.swift', 'TargetPickerView.swift', 'TrollMetadataView.swift']:
    text = source(file)
    assert '.softGroupedRow(' in text and 'top:' in text and 'bottom:' in text, file
    assert '.listRowSeparator(.hidden)' not in text, file  # no blanket hiding

# Every generated semantic group has exactly one first/last edge, including
# combined empty/error/loading/pagination states. Assert terminality, not counts alone.
def edges_ok(edges):
    if not edges: return
    assert sum(t for t, b in edges) == 1 and edges[0][0], edges
    assert sum(b for t, b in edges) == 1 and edges[-1][1], edges

for n, busy, more in itertools.product(range(4), (False, True), (False, True)):
    rows = [(i == 0, i == n - 1 and not more) for i in range(n)]
    if n == 0 and not busy: rows += [(True, not more)]
    if more: rows += [(n == 0 and busy, True)]
    edges_ok(rows)  # ReleaseList
    rows = [(True, False)]  # Attachment picker
    rows += [(False, i == n - 1 and not busy) for i in range(n)]
    if n == 0: rows += [(False, not busy)]
    if busy: rows += [(False, True)]
    edges_ok(rows)
# Attachment metadata and all independently available actions must share one
# continuous group. Only the last visible action closes it, never metadata.
# Cover invalid/absent copy links, read-only/write modes, busy, pagination,
# and heterogeneous link availability across multiple assets.
for n, can_write, busy, more in itertools.product(range(4), (False, True), (False, True), (False, True)):
    for links in itertools.product((False, True), repeat=n):
        rows = []
        for i, has_link in enumerate(links):
            terminal = i == n - 1 and not more
            rows += [(i == 0, False)]  # metadata is followed by download
            rows += [(False, terminal and not has_link and not can_write)]
            if has_link: rows += [(False, terminal and not can_write)]
            if can_write: rows += [(False, terminal)]
        if not n and not more: rows += [(True, True)]
        if more: rows += [(not n, True)]
        edges_ok(rows)
        assert len(rows) == (sum(2 + int(link) + int(can_write) for link in links)
                             + int(not n and not more) + int(more))
        # Every nonterminal native row paints a separator; the terminal row
        # closes the rounded group without an extra outside line.
        assert sum(not bottom for _, bottom in rows) == len(rows) - 1
for busy, error, valid in itertools.product((False, True), repeat=3):
    rows = [(True, False), (False, False), (False, not error and valid)] if busy else []
    if error: rows += [(not busy, valid)]
    if not valid: rows += [(not busy and not error, True)]
    edges_ok(rows)
# Management is now an always-present native row, independent of link state.
for empty in (False, True):
    edges_ok([(True, False), (False, False), (False, True)])
# Native branch rows have one top/bottom even during loading, errors, empty
# catalogue, search, and advanced SHA verification. The fixed hint ends the group.
for loading, count, error, ready, expanded, searching, advanced, matches, sha_target in itertools.product(
        (False, True), (0, 1, 3), (False, True), (False, True),
        (False, True), (False, True), (False, True), (0, 2), (False, True)):
    rows = [(True, False)] if loading else []
    if count:
        rows += [(not loading, False)]
        if count > 1 and expanded:
            rows += [(False, False)]  # search control
            if searching: rows += [(False, False)]
            rows += [(False, False)] * (matches or 1)  # names or empty hint
    if error: rows += [(not loading and count == 0, False)]
    if not loading and not ready: rows += [(count == 0 and not error, False)]
    rows += [(not loading and count == 0 and not error and ready, False)]  # advanced header
    if advanced: rows += [(False, False)] * (2 + int(ready and sha_target))
    rows += [(False, True)]
    edges_ok(rows)
for name, author, section, priority, homepage in itertools.product((False, True), repeat=5):
    rows = ([(True, False)] if name else []) + ([(not name, False)] if author else [])
    rows += [(not name and not author, False)] + [(False, False)] * 4
    rows += [(False, False)] * (section + priority + homepage) + [(False, True)]
    edges_ok(rows)

# cc62549 local allowance is ONLY UI rendering. Preserve the exact historic
# logic and shared decoration, not a broad regex normalization of whole files.
# The Actions checkout is shallow. Fetch only this immutable baseline when it
# is absent; keep the byte-exact protection equally strict locally and in CI.
BASE = 'cc62549598166c4b8b1f3dc5edccc34e3a81037d'
if subprocess.run(['git', 'cat-file', '-e', BASE + '^{commit}'],
                  cwd=REPO_ROOT, capture_output=True).returncode:
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', BASE],
                   cwd=REPO_ROOT, check=True, timeout=120)
def baseline(name):
    return subprocess.check_output(['git', 'show', f'{BASE}:RepoPocket/{name}'], cwd=REPO_ROOT, text=True)
for file in ['WorkspaceSelectionUI.swift', 'GitHub.swift', 'RepositoryUI.swift',
             'RepositoryStar.swift', 'RepositoryStarUI.swift', 'ReleaseManagement.swift',
             'ReleasePublishPlan.swift', 'ReleaseTransfers.swift']:
    current = source(file)
    if file == 'GitHub.swift':
        # Current-account social writes are isolated and covered by native request/state fixtures.
        social_marker = '// Current-account profile writes have their own endpoint and acknowledgement checks.\n'
        assert current.count(social_marker) == 1
        social = current.split(social_marker, 1)[1]
        assert 'path: String = "/user/social_accounts"' in social
        assert 'guard method == "GET" || path == "/user/social_accounts"' in social
        assert 'delegate: OfficialUpdateRedirectPolicy()' in social
        assert 'guard code == expected' in social
        current = current.split(social_marker, 1)[0].removesuffix('\n')
        # Exact additions for the account-scoped follow capability have their own native request/race fixtures.
        current = current.replace('    lazy var follows = UserFollowStore(api: self)\n', '')
        current = current.replace('                self?.follows.invalidate()\n', '')
        follow_start = current.index('    func followIdentity()')
        follow_end = current.index('    private func managedJSON', follow_start)
        current = current[:follow_start] + current[follow_end:]
        # The explicitly approved issue deletion transport has separate native
        # permission, account-generation, and mutation acknowledgement fixtures.
        deletion_start = current.index('    lazy var issueDeletions = IssueDeletionState()')
        deletion_end = current.index('    @Published private(set) var starRevision', deletion_start)
        assert 'func issueDeletionGraphQL(' in current[deletion_start:deletion_end]
        current = current[:deletion_start] + current[deletion_end:]
        transfer_start = current.index('    func downloadManagedAssetWithProgress(')
        transfer_end = current.index('\n    }', transfer_start) + len('\n    }') + 1
        assert 'ReleaseAssetDownloadDelegate(update: transfer)' in current[transfer_start:transfer_end]
        current = current[:transfer_start] + current[transfer_end:]
        # The authorized metadata editor has separate permission/race tests.
        description_start = current.index('    func descriptionContext(')
        description_end = current.index('    func deletionContext(', description_start)
        current = current[:description_start] + current[description_end:]
        # This feature adds a read-only community gateway and search options;
        # normalize only their exact expressions, keeping all writes frozen.
        start = current.index('    // Read-only gateway')
        end = current.index('    func searchUsers(', start)
        gateway = current[start:end]
        read_gateway = gateway.split('    // Native collaboration transport:')[0]
        assert 'try await data(path, query: query)' in read_gateway and 'method:' not in read_gateway
        current = current[:start] + current[end:]
        current = current.replace('page: Int, options: RepositorySearchOptions = .init()) async throws -> RepositorySearchResponse', 'page: Int) async throws -> RepositorySearchResponse')
        current = current.replace('query: query, page: page, options: options)', 'query: query, page: page)')
        # Explicit fork-status fix: new lookup and accepted-POST bookkeeping are
        # covered by test_repository_fork_status.py. Keep every unrelated byte
        # of the historic transport and mutation guards protected below.
        current = current.replace('    let source: RepositoryReference?\n', '')
        current = current.replace('    @Published private(set) var forkNames: [String: String] = [:]\n', '')
        current = current.replace('    private var forkChecks: [String: Task<String?, Error>] = [:]\n', '')
        current = current.replace('    private var forkCheckedAt: [String: Date] = [:]\n', '')
        current = current.replace('    private var forkCheckIDs: [String: UUID] = [:]\n', '')
        fork_start = current.index('    // Fork status is read only, on demand, and scoped to this account generation.')
        fork_end = current.index('    func fork(_ repo: String)', fork_start)
        current = current[:fork_start] + current[fork_end:]
        accepted_post = '''        let result = try await decoded(Repository.self, endpoint + "/forks", method: "POST", object: [:])
        try ensureActiveAccount()
        // The accepted POST itself confirms this relationship, even before metadata is ready.
        if RepositoryGroupRules.isOwned(result.full_name, login: login) {
            let key = (try RepositoryInput.parse(repo)).lowercased()
            forkNames[key] = result.full_name
            forkCheckedAt[key] = Date()
        }
        return result'''
        assert current.count(accepted_post) == 1
        current = current.replace(accepted_post, '        return try await decoded(Repository.self, endpoint + "/forks", method: "POST", object: [:])')
        # Explicit fork-write revalidation is covered by production fork fixtures.
        revalidation = '        guard try await existingFork(repo) == nil else { throw AppError(text: "此仓库已复刻。") }\n        try ensureActiveAccount()\n'
        assert current.count(revalidation) == 1
        current = current.replace(revalidation, '')
        # File-backed Git blob uploads, queue limits, and TrollFools streaming
        # intentionally replace their old in-memory implementations. Their
        # behavior has focused regression tests; restore only these methods for
        # the byte-exact guard on unrelated legacy GitHub code below.
        helper_start = current.index('    private func uploadGitBlobFile(')
        helper_end = current.index('    func history(', helper_start)
        current = current[:helper_start] + current[helper_end:]
        old_github = baseline(file)
        for signature, next_signature in (
            ('    func commitQueue(', '    func identify('),
            ('    func trollPublish(', '    func metadataSnapshot('),
        ):
            current_start = current.index(signature)
            current_end = current.index(next_signature, current_start)
            old_start = old_github.index(signature)
            old_end = old_github.index(next_signature, old_start)
            current = current[:current_start] + old_github[old_start:old_end] + current[current_end:]
        # Signed-out update checks use the public releases endpoint; the
        # anonymous path is covered by test_app_update.py.
        current = current.replace(
            '    /// The public releases endpoint works signed out; a token only raises the rate limit.\n'
            '    var canCheckOfficialUpdate: Bool { isCurrentSession }\n', '')
        release_start = current.index('    func officialAppUpdateData(')
        release_end = current.index('    func ', release_start + 20)
        old_release_start = old_github.index('    func officialAppUpdateData(')
        old_release_end = old_github.index('    func ', old_release_start + 20)
        current = current[:release_start] + old_github[old_release_start:old_release_end] + current[release_end:]
        current = current.replace('session.data(for: r, delegate: GitHubAPIRedirectPolicy())',
                                  'session.data(for: r, delegate: OfficialUpdateRedirectPolicy())')
        # Account-sheet integration tests inject an isolated URL protocol through
        # the session configuration; preserve the byte guard for unrelated API code.
        current = current.replace(
            '    init(configuration: URLSessionConfiguration = .ephemeral) {\n'
            '        let config = configuration.copy() as! URLSessionConfiguration\n',
            '    init() {\n        let config = URLSessionConfiguration.ephemeral\n')
    if file == 'WorkspaceSelectionUI.swift':
        # Separator implementation may change; 1.0.4 shape and layout stay exact.
        assert current.split('extension View {\n    ///')[0] == baseline(file).split('extension View {\n    ///')[0]
    elif file == 'RepositoryUI.swift':
        # Approved star/fork navigation changes only this rendering block.
        old = baseline(file)
        begin, end = 'struct RepositoryStatistics:', '/// The same compact summary'
        assert current.split(begin)[0] == old.split(begin)[0]
        assert current.split('struct LoadingRows:')[1] == old.split('struct LoadingRows:')[1]
        assert current.split('.task(id: repository.id) {')[1].split('.sheet(isPresented: $showParent)')[0] == old.split('.task(id: repository.id) {')[1].split('.sheet(isPresented: $showParent)')[0]
        assert 'openOwner: openOwner' in current
        assert 'repositorySocialAPI' in current and 'RepositorySocialView' in current
    elif file == 'RepositoryStarUI.swift':
        # The home action adds retryable status reads. Preserve the complete
        # mutation/captured-account branch and the existing statistics view.
        old = baseline(file)
        old_prefix = old[old.index('struct RepositoryStarMenuButton'):old.index('            } else {\n                Button { api.message = error')]
        assert current[current.index('struct RepositoryStarMenuButton'):current.index('            } else {\n                Button { Task')] == old_prefix
        assert current.split('struct StarAwareRepositoryStatistics')[1] == old.split('struct StarAwareRepositoryStatistics')[1]
        old_read = old.split('        .task(id: name) {\n')[1].split('        }\n    }\n}')[0]
        assert old_read in current
        assert '.task(id: name) { await load() }' in current
        assert 'Button { Task { await load() } }' in current
    else:
        assert current == baseline(file), file
def function_blocks(text):
    import re
    matches = list(re.finditer(r'^    (?:@MainActor )?(?:private |static )*func [^\n]*', text, re.M))
    result = {}
    for match in matches:
        start = match.start()
        opening = text.index('{', start)
        depth, quote, escaped = 1, False, False
        index = opening + 1
        while depth:
            char = text[index]
            if quote:
                if escaped: escaped = False
                elif char == '\\': escaped = True
                elif char == '"': quote = False
            elif char == '"': quote = True
            elif char == '{': depth += 1
            elif char == '}': depth -= 1
            index += 1
        signature = text[start:opening].strip()
        result[signature] = text[opening:index]
    return result
# Original-folder association deliberately changes only import and scan below.
# Native filesystem/bookmark regression coverage lives in test_linked_workspaces.py.
workspace_operations = (
    'static func metadata(', 'static func snapshot(',
    'static func removeWorkspace(', 'static func renameWorkspace(',
    '@MainActor private func importItems(', '@MainActor private func scan()',
)

def restore_workspace_operations(current, old):
    current_blocks, old_blocks = function_blocks(current), function_blocks(old)
    for signature, body in old_blocks.items():
        if any(signature.startswith(prefix) for prefix in workspace_operations):
            assert signature in current_blocks, signature
            updated = current_blocks[signature]
            assert current.count(updated) == 1, signature
            current = current.replace(updated, body, 1)
    return current

for file, marker in [
    ('ReleaseBranchPicker.swift', 'struct ReleaseBranchPicker: View {'),
    ('ReleaseEntryView.swift', '    private func proceed() async {'),
    ('TargetPickerView.swift', '    private func load() async {'),
    ('RepositorySearchView.swift', '    private func begin('),
    ('DebEditorView.swift', '    private var editorPresentation: some View {'),
    ('WorkspaceView.swift', '    @MainActor private func importItems('),
    ('TrollMetadataView.swift', '    @MainActor private func load() async {')]:
    current, old = source(file), baseline(file)
    if file == 'ReleaseBranchPicker.swift':
        assert current.split(marker)[0] == old.split(marker)[0], file
    elif file == 'WorkspaceView.swift':
        current = restore_workspace_operations(current, old)
        assert current.split(marker, 1)[1] == old.split(marker, 1)[1], file
    elif file == 'RepositorySearchView.swift':
        # UserRepositories UI is also explicitly allowed, its network code isn't.
        current = current.replace('        requestedOptions = options\n', '')
        current = current.replace('requested, page: requestedPage, options: requestedOptions)', 'requested, page: requestedPage)')
        assert current.split('    private func invalidate()')[1].split('struct UserRepositoriesView:')[0] == old.split('    private func invalidate()')[1].split('struct UserRepositoriesView:')[0]
        assert 'RepositorySearchRouting.repository(clean)' in current
        assert current.split('    private func load() async {')[-1] == old.split('    private func load() async {')[-1]
    else:
        assert current.split(marker, 1)[1] == old.split(marker, 1)[1], file
print('PASS feature-page matrices: release pagination/status/attachments, direct management entry and 32 optional deb field combinations; native branch/SHA expansion boundaries; exact cc62549 business/shared-style protection')

# Byte-exact operation bodies for mixed UI/logic files: rendering may move, API
# calls/cancellation/permission and destructive confirmation logic may not.
for file in ['RepoPocketApp.swift', 'DesktopViews.swift', 'ReleaseManagementUI.swift',
             'UploadView.swift', 'RepositoryDeletionView.swift', 'RepositorySections.swift',
             'AccountManagement.swift', 'DebEditorView.swift', 'TargetPickerView.swift',
             'ReleaseEntryView.swift', 'WorkspaceView.swift', 'TrollMetadataView.swift']:
    old, current = function_blocks(baseline(file)), function_blocks(source(file))
    # Only these three functions produce UI rather than business actions.
    rendering = ['workspaceManagement(', 'bindingSection(', 'outputSection(']
    for signature, body in old.items():
        if any(token in signature for token in rendering): continue
        if file == 'WorkspaceView.swift' and any(signature.startswith(prefix) for prefix in workspace_operations):
            # Explicitly replaced by linked-directory production regressions.
            assert signature in current, signature
            continue
        if file == 'RepoPocketApp.swift' and signature == 'private func verify() async':
            # Intentional fix: the pasted Token must survive a failed verification, and the
            # first attempt dropped by the system network prompt is retried once.
            assert 'TokenVerification.submit(credential)' in current.get(signature, ''), signature
            assert 'let credential = token; token = ""' not in current.get(signature, ''), signature
            assert 'token = ""' in current.get(signature, ''), signature
            continue
        if file == 'RepoPocketApp.swift' and signature in ('private func zip() async', 'private func download() async'):
            # Downloads now save directly to the chosen folder and report the
            # result with the approved native ZIP completion alert; focused
            # download tests protect this changed path and the file fallback.
            body = current.get(signature, '')
            assert 'try await DownloadStore.shared.persist(' in body, signature
            if signature == 'private func zip() async':
                assert 'downloadedZIP = saved' in body, signature
            else:
                assert 'downloadedFile = saved' in body, signature
            assert 'ShareSheet' not in body and 'share = ' not in body, signature
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'func run(_ work: @escaping () async throws -> Void)':
            # The shared operation runner now clears the inline download notice
            # whenever another release-management operation starts.
            body = current.get(signature, '')
            assert 'guard valid, !busy else { return }' in body
            assert 'error = ""; notice = ""; progress = 0' in body
            assert 'defer { if operation == token { busy = false; task = nil } }' in body
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'func cancel()':
            assert 'task?.cancel()' in current[signature] and 'assetDownload?.stage = .cancelled' in current[signature]
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'func list(reset: Bool)':
            # Confirmed edits/deletions preserve loaded rows; production controller fixtures cover paging and stale responses.
            changed = current.get(signature, '')
            assert 'self.api.managedReleases(self.repo, page: p); try self.check()' in changed
            assert 'batch.filter { !self.removedReleaseIDs.contains($0.id) }' in changed
            assert 'self.removedReleaseIDs = []' in changed
            assert 'self.api.managedLatestID(self.repo, refresh: true); try self.check()' in changed
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'func download(_ asset: Asset)':
            body = current.get(signature, '')
            assert 'self.downloader.download(' in body
            assert 'try await self.downloader.persist(' in body
            assert 'self.completedDownload = saved' in body
            assert 'SharedFile' not in body and 'self.saved' not in body
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'private func performDelete()':
            # Deletion confirms once; the destructive guard keeps the fixed
            # repo/session identity checks and drops the typed confirmation.
            body = current.get(signature, '')
            assert 'target.repo == state.repo' in body
            assert 'target.generation == AccountStore.generation' in body
            assert 'confirmation' not in body and 'secondDelete' not in body
            assert 'deleteManagedRelease' in body
            continue
        if file == 'UploadView.swift' and signature == 'private func select(_ result: Result<[URL], Error>) async':
            # TrollFools plugins are capped before and after preparation, while
            # regular Release assets retain their separate larger limit.
            body = current.get(signature, '')
            assert 'RepoQueue.maximumTrollPluginBytes' in body
            assert 'guard size > 0' in body and 'guard actual > 0' in body
            assert 'size < 2 * 1024 * 1024 * 1024' in body
            assert 'DebControlEditor.prepareForUpload' in body
            continue
        if file == 'UploadView.swift' and signature == 'private func saveAsset(_ asset: Asset, repo: String) async':
            body = current.get(signature, '')
            assert 'api.downloadAsset' in body
            assert 'try await DownloadStore.shared.persist(' in body
            assert 'downloadedAsset = saved' in body
            assert 'api.isCurrentSession' in body
            assert 'SharedFile' not in body
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'private func stage(_ result: Result<[URL], Error>)':
            # Inbox selections add cleanup after the existing attachment copy.
            changed = current.get(signature, '')
            assert 'ShareSelectionCleanup.remove(urls)' in changed
            assert changed.replace('ShareSelectionCleanup.remove(urls); ', '') == body
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'private func upload(_ file: URL, to r: ManagedRelease)':
            changed = current.get(signature, '')
            expected = body.replace('guard file.startAccessingSecurityScopedResource() else { throw AppError(text: "文件未授权，请重选。") }\n            defer { file.stopAccessingSecurityScopedResource() }', 'let scoped = file.startAccessingSecurityScopedResource()\n            defer { if scoped { file.stopAccessingSecurityScopedResource() }; ShareSelectionCleanup.remove([file]) }\n            guard FileManager.default.isReadableFile(atPath: file.path) else { throw AppError(text: "文件未授权，请重选。") }')
            assert changed == expected, signature
            continue
        if file == 'RepoPocketApp.swift' and signature in ('private func read() async', 'private func save() async'):
            # Approved file-reader redesign: automatic bounded reading and a
            # dedicated editor replace the old manual Form actions. Production
            # text/lexer and page-request regressions cover the replacement.
            continue
        assert current.get(signature) == body, (file, signature)
print('PASS byte-exact baseline operation bodies: account, navigation/API actions, local/remote workspace, upload, release and destructive guards')
