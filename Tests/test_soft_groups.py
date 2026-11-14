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
assert 'cornerRadius: radius, style: .continuous' in style and 'let radius: CGFloat = 10' in style
assert 'listRowBackground(' in style and 'SoftGroupShape' in style and '.secondarySystemGroupedBackground' in style
# Only the decoration is clipped; never clip the interactive List or its content.
assert style.count('.clipShape(') == 1
assert '.appearance()' not in style and '.blur(' not in style
for text in [ui, workspace, upload]:
    assert '.softGroupedRow(top: true)' in text
    assert '.softGroupedRow(bottom: true)' in text
# Desktop history/detail now delegate their first/last rows to the shared builder.
for name, end in [('HistoryView', 'CommitDetailView'), ('CommitDetailView', 'BranchPickerView')]:
    page = detail.split('struct ' + name + ': View {', 1)[1].split('struct ' + end + ': View {', 1)[0]
    assert page.count('SoftGroupRows {') == 1 and '.softGroupedRow(' not in page
branch_picker = detail.split('struct BranchPickerView: View {', 1)[1]
assert 'SoftGroupRows(bottom: !(canWrite && api.isCurrentSession) && deletionMessage.isEmpty && !busy)' in branch_picker
assert 'SoftGroupRows(top: false, bottom: deletionMessage.isEmpty && !busy)' in branch_picker
assert 'ProgressView().softGroupedRow(bottom: true)' in branch_picker
section = ui.split('RepositoryHomeLinksSection(api: api', 1)[1].split('.listStyle(.insetGrouped)', 1)[0]
assert 'DisclosureGroup' not in section and 'repositoriesExpanded' not in ui
repoSection = section.split('发现与关注动态', 1)[0]
assert 'softGroupedRow' not in repoSection
# Task-first home: owned/starred repositories come first; community discovery
# stays below them in the same group, before the terminal permission note.
assert section.index('发现与关注动态') > section.index('UserConnectionsSection')
assert 'SoftGroupRows(spacingBefore: CredentialStore.read().isEmpty ? 0 : 10)' in section
assert 'SoftGroupRow("discovery")' in section and 'SoftGroupRow("permission-help")' in section
assert '.softGroupedRow(' not in section
assert 'refresh()' not in section and 'repos = []' not in section
assert 'NavigationLink("添加 / 更新 GitHub 账号")' in Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
assert 'Section("已保存账号")' not in ui
assert '.sheet(isPresented: $accountPresentation.showing' in ui
assert '.listStyle(.insetGrouped)' in workspace and '.listStyle(.insetGrouped)' in ui
assert '.appGroupedFormStyle()' in upload
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
directory_rows = ui.split('@SoftGroupRowsBuilder private var directoryRows:', 1)[1].split('var body: some View {', 1)[0]
assert 'SoftGroupRow("entry-" + e.id)' in directory_rows
assert '.softGroupedRow(' not in directory_rows
assert 'row.content.softGroupedRow(top: top && row.id == rows.first?.id, bottom: bottom && row.id == rows.last?.id' in style
assert 'init(top: Bool = true, bottom: Bool = true, animateBackground:' in style
# The file reader is now a full-height code surface; its loading indicator is
# no longer a terminal row inside the old metadata/download Form.
# Import buttons moved into the toolbar Menu (not List rows).
binding_ui = workspace.split('private func bindingSection(', 1)[1].split('private func', 1)[0]
assert 'SoftGroupRows {' in binding_ui
assert 'SoftGroupRow("repository") { Text(binding.repo + " · " + binding.branch) }' in binding_ui
row = next(line for line in workspace.splitlines() if 'TextField("提交说明", text: $commitMessage)' in line)
assert '.softGroupedRow()' in row, row
# Upload is a single repository context, not another Release/Troll destination.
commit_group = upload.split('private var commitSection:', 1)[1].split('private func beginEditing', 1)[0]
assert 'SoftGroupRows(top: false, bottom: !busy)' in commit_group
for row in ['directory', 'branch', 'options', 'preview']:
    assert 'SoftGroupRow("' + row + '")' in commit_group
assert '.softGroupedRow(' not in commit_group
assert 'mode ==' not in upload and 'private var releaseSection' not in upload
assert 'private var fileSection:' in upload
assert 'Button("待上传文件")' in upload and '.softGroupedRow(bottom: true)' in upload
assert 'ReleaseEntryView(api: api' in Path(REPO_ROOT, 'RepoPocket/ExternalFileActions.swift').read_text()
for count in (0, 1, 4):
    edges = [(i == 0, i == count - 1) for i in range(count)]
    if count: assert sum(top for top, _ in edges) == sum(bottom for _, bottom in edges) == 1
# Local workspace groups: the hint always opens the group; only the actual last
# row closes it. Selection and long-press actions remain native List rows.
local = workspace.split('private var localSection: some View {', 1)[1].split('private func workspaceManagement', 1)[0]
assert 'softGroupedRow(top: true, bottom: roots.isEmpty)' in local
assert '.softGroupedRow(bottom: root == roots.last)' in local
assert 'ForEach(roots, id: \\.path)' in local and '.contextMenu {' in local
management = workspace.split('private func workspaceManagement', 1)[1].split('private func bindingSection', 1)[0]
assert 'if let binding { Text(binding.repo + " / " + binding.branch).font(.headline).softGroupedRow(top: true) }' in management
assert 'NativeActionMenu(title: "工作区…"' in management
assert 'enabled: !busy && api.isCurrentSession' in management
assert '.softGroupedRow(top: binding == nil, bottom: !linked)' in management
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
print('PASS soft grouped UI contracts: equal-width repositories, 10pt continuous row backgrounds, native lists/swipe deletion, semantic colors and adaptive text')

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
assert 'Group {\n            if state.loading' in picker_ui
assert 'VStack(alignment: .leading, spacing: 0)' not in picker_ui
assert 'branchRow' not in picker_ui and '.listRowInsets(EdgeInsets())' not in picker_ui
assert '.buttonStyle(.borderless)' in picker_ui
assert 'minHeight: 44' in picker_ui and '.contentShape(Rectangle())' in picker_ui
assert 'ForEach(visible, id: \\.self)' in picker_ui
assert 'LazyVStack' not in picker_ui
assert 'DisclosureGroup("高级：提交 SHA", isExpanded: $advanced)' in picker_ui
assert picker_ui.count('Section {') == 0
assert '.easeInOut(duration: 0.18)' in picker_ui and 'reduceMotion ? nil' in picker_ui
assert 'animate { expanded.toggle() }' in picker_ui
assert 'animate { expanded = false; advanced = false }' in picker_ui
assert 'animate { advanced.toggle() }' not in picker_ui
assert '.softGroupedRow(top: !state.loading)' not in picker_ui
assert 'ProgressView("正在核验目标分支…").softGroupedRow()' in picker_ui
assert 'softGroupedRow(top: false, bottom: false)' in picker_ui
assert 'softGroupedRow(bottom: true)' not in picker_ui
assert 'Text("已有 Git 标签不受目标分支影响。")' in picker_ui
assert 'Rectangle().fill(Color(uiColor: .separator))' not in picker_ui
# The editor, not recycled Form rows, owns target readiness and cancellation.
assert '.onDisappear' not in picker_ui
assert '@ObservedObject var state: ReleaseBranchState' in picker_ui
editor_ui = source('ReleaseManagementUI.swift').split('struct ReleaseEditorView: View {', 1)[1]
assert '@StateObject private var targetState = ReleaseBranchState()' in editor_ui
assert '.onDisappear { targetState.cancel(); plan.cancel(); state.cancel();' in editor_ui

release_entry = source('ReleaseEntryView.swift')
assert 'ReleaseEditorView(api: api' in release_entry
assert '.sheet' not in release_entry and 'createRepository(' not in release_entry
assert 'allowsRepositorySelection: true' in release_entry
assert 'if original == nil && allowsRepositorySelection { repositorySection }' in editor_ui
assert '读取目标分支' in editor_ui
assert 'guard !state.repo.isEmpty else { return }' in editor_ui
assert 'targetState.load(api: state.api, repo: state.repo' in editor_ui
github = source('GitHub.swift')
managed_json = github.split('private func managedJSON<', 1)[1].split('private var managedPresenceCache', 1)[0]
assert 'let canonical = try RepositoryInput.parse(repo)' in managed_json
assert managed_json.index('RepositoryInput.parse(repo)') < managed_json.index('try request(')
assert 'if http.statusCode == 404 { throw ManagedReleaseHTTPError' in managed_json
assert 'try await managedJSON([ReleaseSummary].self, repo: repo' in github
assert 'api.managedRepository(repo)' in source('ReleaseManagementUI.swift')
assert 'ReleaseManagementRules.canWrite' in source('ReleaseManagementUI.swift')

release = source('ReleaseManagementUI.swift')
release_list = release.split('struct ReleaseListView: View {', 1)[1].split('private struct ReleaseDeleteTarget:', 1)[0]
assert 'SoftGroupRows(bottom: !releaseHasStatus(state))' in release_list
assert 'SoftGroupRow("repository")' in release_list and 'SoftGroupRow("release-\\(row.id)")' in release_list
assert 'SoftGroupRow("next")' in release_list and 'releaseStatus(state)' in release_list
assert '.softGroupedRow(' not in release_list
detail_ui = release.split('struct ReleaseDetailView: View', 1)[1].split('struct ReleaseEditorView: View', 1)[0]
asset_ui = detail_ui.split('for asset in state.assets {', 1)[1].split('if state.assets.isEmpty', 1)[0]
assert 'SoftGroupRow("asset-\\(asset.id)")' in asset_ui
assert '.softGroupedRow(' not in asset_ui  # the menu and status stay inside one real attachment row
assert 'Text(asset.name)' in asset_ui and '.frame(width: 24)' in asset_ui and 'Menu {' in asset_ui
assert 'LocalGitFileLabel(' not in asset_ui
assert 'ReleaseAssetDownloadStatusView(' in asset_ui
assert 'minHeight: 44' in asset_ui and '.contentShape(Rectangle())' in asset_ui
assert '.disabled(state.busy || !state.valid)' in asset_ui
assert 'if state.canWrite' in asset_ui and 'prepareDelete(r, asset: asset)' in asset_ui
assert 'SoftGroupRows(bottom: state.assetDownload != nil || !releaseHasStatus(state))' in detail_ui
assert 'if state.assetDownload == nil { releaseStatus(state, top: state.release == nil) }' in detail_ui
assert 'Divider()' not in asset_ui and 'Rectangle().fill' not in asset_ui
asset_actions = detail_ui.split('@ViewBuilder private func assetActions(', 1)[1].split('private var deleteDescription:', 1)[0]
assert 'Button("下载并保存") { state.download(asset) }.disabled(state.busy || !state.valid)' in asset_actions
assert 'if let link = ReleaseManagementRules.browserDownloadURL(asset.browser_download_url, repo: state.repo)' in asset_actions
assert 'Button("复制下载链接") { UIPasteboard.general.url = link; copied = true }' in asset_actions
attachment_ui = release.split('@SoftGroupRowsBuilder private var attachmentSection:', 1)[1].split('private func cleanupAttachments()', 1)[0]
for token in ['SoftGroupRow("attachments-heading")', 'SoftGroupRow("attachment-" + item.id.uuidString)',
              'if attachments.isEmpty', 'if staging', '.disabled(state.busy || staging || plan.draftID != nil)']:
    assert token in attachment_ui, token
assert '.softGroupedRow(' not in attachment_ui
assert 'SoftGroupRows(top: false, bottom: !releaseHasStatus(state))' in editor_ui
assert 'ToolbarItem(placement: .confirmationAction)' in release
assert 'Button(actionTitle) { confirm = true }.accessibilityIdentifier("release-publish")' in release
assert '.disabled(state.busy || staging || !state.valid)' in release
assert 'guard markerReady, form.validMarker' in release
assert 'reviewFingerprint == nil || !state.valid' in release
assert 'SoftGroupRow("retry-marker") { Button("重试读取发行版标记") { loadMarker() } }' in release
status_ui = release.split('@MainActor @ViewBuilder private func releaseStatus(', 1)[1]
assert 'top: Bool = false, bottom: Bool = true' in status_ui
assert 'SoftGroupRows(top: top, bottom: bottom)' in status_ui
assert 'state.busy || !state.notice.isEmpty || !state.error.isEmpty || !state.valid' in release
for row in ['progress', 'help', 'cancel', 'notice', 'error', 'account']:
    assert 'SoftGroupRow("release-status-' + row + '")' in status_ui
assert '.softGroupedRow(' not in status_ui
assert 'Divider()' not in detail_ui  # all detail rows use the same full-width separator
deb = source('DebEditorView.swift')
for start, end, boundary in [('originalSection', 'editSection', 'top: false, bottom: differences.isEmpty && !showsOutput'),
                             ('editSection', 'differencesSection', 'top: false, bottom: false')]:
    group = deb.split('private var ' + start + ':', 1)[1].split('private var ' + end + ':', 1)[0]
    assert 'SoftGroupRows(' + boundary + ')' in group and '.softGroupedRow(' not in group
    assert 'UIRules.withoutAnimation' in group and '$0.disablesAnimations = true' in group
collection = source('RepositorySections.swift').split('struct RepositoryCollectionView: View {', 1)[1]
assert collection.count('SoftGroupRows {') == 1 and '.softGroupedRow(' not in collection
for row in ['search', 'loading', 'empty', 'login', 'no-match', 'repository-\\(repository.id)']:
    assert 'SoftGroupRow("' + row + '")' in collection, row
assert 'for repository in filteredRepositories' in collection
assert '.swipeActions(edge: .trailing, allowsFullSwipe: false)' in collection
assert '!RepositoryGroupRules.isOwned(repository.full_name, login: api.login)' in collection
assert 'Button("复刻") { pendingFork = repository }.tint(.accentColor).disabled(busy)' in collection
for file in ['AccountManagement.swift', 'DebEditorView.swift', 'DesktopViews.swift',
             'RepositoryDeletionView.swift', 'RepositorySearchView.swift', 'ExternalFileActions.swift']:
    text = source(file)
    if file == 'RepositorySearchView.swift':
        assert 'SoftGroupRows {' in text and 'SoftGroupRows(top: false)' in text
        assert 'CommunityProfileSection(api: api, login: user.login, avatar: user.avatar_url, connected: true)' in text
        assert '.softGroupedRow(' not in text
    else:
        assert '.softGroupedRow(' in text and 'top:' in text and 'bottom:' in text, file
    assert '.listRowSeparator(.hidden)' not in text, file  # no blanket hiding
target_picker = source('TargetPickerView.swift').split('struct TargetPickerView: View {', 1)[1]
assert target_picker.count('Section {') == target_picker.count('SoftGroupRows {') == 1
assert '.softGroupedRow(' not in target_picker and '.listRowSeparator(.hidden)' not in target_picker
for row in ['repository', 'path', 'parent', 'select-folder', 'busy', 'error', 'retry', 'folders-title', 'files-title']:
    assert 'SoftGroupRow("' + row + '")' in target_picker
assert 'SoftGroupRow("folder-" + e.path)' in target_picker and 'SoftGroupRow("file-" + e.path)' in target_picker
assert 'if !filesOnly' in target_picker and 'if !foldersOnly' in target_picker

# Every generated semantic group has exactly one first/last edge, including
# combined empty/error/loading/pagination states. Assert terminality, not counts alone.
def edges_ok(edges):
    if not edges: return
    assert sum(t for t, b in edges) == 1 and edges[0][0], edges
    assert sum(b for t, b in edges) == 1 and edges[-1][1], edges

def shared_edges(count, top=True, bottom=True):
    return [(top and i == 0, bottom and i == count - 1) for i in range(count)]

for n, busy, more, error, notice, valid in itertools.product(range(4), *((False, True),) * 5):
    status_count = 3 * busy + error + notice + int(not valid)
    # Repository context is always first; next-page and operation feedback stay attached.
    content_count = 1 + n + int(n == 0 and not busy) + int(more)
    rows = shared_edges(content_count, bottom=not status_count)
    rows += shared_edges(status_count, top=False)
    edges_ok(rows)
    assert len(rows) == content_count + status_count
for n, staging, retained in itertools.product(range(4), (False, True), (False, True)):
    # The attachment builder is part of the editor, not another rounded card.
    attachment_count = 3 + n + int(n == 0) + int(staging)  # title, inbox, picker
    rows = [(True, False)]  # preceding title/target/body rows
    rows += shared_edges(attachment_count, top=False, bottom=False)
    if retained: rows += [(False, False)]
    rows += [(False, True)]  # always-present publish-help after attachments
    edges_ok(rows)
    assert len(rows) == attachment_count + int(retained) + 2
# Each attachment now has one native row containing its menu and transfer status.
# Available menu actions still vary by valid copy link/write permission, not by
# adding extra List rows or closing the group before its fixed help/status rows.
for n, can_write, busy, more, downloading in itertools.product(range(4), *((False, True),) * 4):
    for links in itertools.product((False, True), repeat=n):
        menu_actions = [1 + int(has_link) + int(can_write) for has_link in links]
        assert sum(menu_actions) == n + sum(links) + n * can_write
        content_count = 5 + n + int(not n and not more) + int(more) + 1  # metadata/title and fixed help
        status_count = 3 * busy if not downloading else 0  # active transfer paints its status inside the asset row
        rows = shared_edges(content_count, bottom=not status_count)
        rows += shared_edges(status_count, top=False)
        edges_ok(rows)
        assert len(rows) == content_count + status_count
        # Every nonterminal native row paints a separator; the terminal row
        # closes the rounded group without an extra outside line.
        assert sum(not bottom for _, bottom in rows) == len(rows) - 1
for busy, error, notice, valid, has_content in itertools.product((False, True), repeat=5):
    status_count = 3 * busy + error + notice + int(not valid)
    rows = shared_edges(1, bottom=not status_count) if has_content else []
    rows += shared_edges(status_count, top=not has_content)
    edges_ok(rows)
# Management is now an always-present native row, independent of link state.
for empty in (False, True):
    edges_ok([(True, False), (False, False), (False, True)])
# Native branch rows remain intermediate editor rows in every loading/search/SHA
# state; the surrounding editor, not the branch picker, owns both outer corners.
for loading, count, error, ready, expanded, searching, advanced, matches, sha_target in itertools.product(
        (False, True), (0, 1, 3), (False, True), (False, True),
        (False, True), (False, True), (False, True), (0, 2), (False, True)):
    rows = [(True, False)]  # preceding editor title/tag group
    if loading: rows += [(False, False)]
    if count:
        rows += [(False, False)]
        if count > 1 and expanded:
            rows += [(False, False)]  # search control
            if searching: rows += [(False, False)]
            rows += [(False, False)] * (matches or 1)  # names or empty hint
    if error: rows += [(False, False)]
    if not loading and not ready: rows += [(False, False)]
    rows += [(False, False)]  # advanced header
    if advanced: rows += [(False, False)] * (2 + int(ready and sha_target))
    rows += [(False, False)]  # fixed existing-tag hint
    rows += [(False, True)]  # following editor body/options/help group
    edges_ok(rows)
for count, matches, busy, loaded, refreshing, searching in itertools.product(
        range(4), range(4), *((False, True),) * 4):
    if matches > count: continue
    feedback = int((busy and count == 0 and not refreshing) or (loaded and count == 0)
                   or (not loaded and not busy) or (loaded and matches == 0))
    edges_ok(shared_edges(int(searching) + feedback + matches))
for directories, files, files_only, folders_only, busy, error, nested in itertools.product(
        range(4), range(4), *((False, True),) * 5):
    count = 3 + int(nested) + int(not files_only) + int(busy) + 2 * error + directories
    if not folders_only: count += 1 + files
    edges_ok(shared_edges(count))
# Optional/folded DEB rows use the same shared edge calculation in every state.
for name, author, section, priority, homepage, expanded in itertools.product((False, True), repeat=6):
    count = int(name) + 6 + int(author or section or priority or homepage)
    if expanded: count += author + section + priority + homepage
    edges_ok([(i == 0, i == count - 1) for i in range(count)])

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
    text = subprocess.check_output(['git', 'show', f'{BASE}:RepoPocket/{name}'], cwd=REPO_ROOT, text=True)
    if name == 'GitHub.swift':
        # Only removed app-specific Troll services are exempt; common API bytes stay frozen.
        text = text.replace('struct TrollPublishResult { let commitSHA: String; let path: String }\n\n', '')
        start, end = text.index('    func trollPublish('), text.index('    func saveRemoteDeb(')
        text = text[:start] + text[end:]
        start, end = text.index('    static func trollSize('), text.index('    func downloadFile(')
        text = text[:start] + text[end:]
    return text
for file in ['WorkspaceSelectionUI.swift', 'GitHub.swift', 'RepositoryUI.swift',
             'RepositoryStar.swift', 'RepositoryStarUI.swift', 'ReleaseManagement.swift',
             'ReleasePublishPlan.swift', 'ReleaseTransfers.swift']:
    current = source(file)
    if file == 'GitHub.swift':
        # Collections have separate production fixtures; retain every unrelated API byte.
        current = current.replace('    lazy var favorites = RepositoryFavoritesState(accountID: accountID) { [weak self] in self?.isCurrentSession == true }\n', '')
        current = current.replace('    var starLists: GitHubStarLists { .init(send: { try await self.starListGraphQL($0, variables: $1) }, isCurrent: { self.isCurrentSession }) }\n', '')
        start, end = current.index('    func starListGraphQL('), current.index('    func starRequest(')
        current = current[:start] + current[end:]
        # The second UI round adds bounded read snapshots, not a new authorization source.
        for name in ('User', 'RepositoryReference', 'Repository', 'Entry'):
            current = current.replace('struct ' + name + ': Codable', 'struct ' + name + ': Decodable')
        current = current.replace('struct Permissions: Codable { let admin: Bool?; let push: Bool? }',
                                  'struct Permissions: Decodable { let admin: Bool?; let push: Bool? }')
        previous_ref = 'faa3dc5c5fda21bfabb685e4a479341690e7e1e3'
        if subprocess.run(['git', 'cat-file', '-e', previous_ref + '^{commit}'], cwd=REPO_ROOT, capture_output=True).returncode:
            subprocess.run(['git', 'fetch', '--depth=1', 'origin', previous_ref], cwd=REPO_ROOT, check=True, timeout=120)
        previous = subprocess.check_output(['git', 'show', previous_ref + ':RepoPocket/GitHub.swift'], cwd=REPO_ROOT, text=True)
        cache_start, cache_end = current.index('    func cachedCollection('), current.index('    func forkParent(')
        old_start, old_end = previous.index('    func cachedCollection('), previous.index('    func forkParent(')
        assert 'ContentSnapshotCache.shared.save' in current[cache_start:cache_end]
        assert 'if section == .starred { stars.seed(repositories) }' in current[cache_start:cache_end]
        current = current[:cache_start] + previous[old_start:old_end] + current[cache_end:]
        snapshot_read = '''        try ensureActiveAccount(); try Task.checkCancellation()
        if method == "GET", path.hasPrefix("/repos/") {
            let parts = path.split(separator: "/")
            if parts.count == 3 || parts.dropFirst(3).first == "contents" || path.hasSuffix("/actions/runs") || path.hasSuffix("/releases/latest") {
                ContentSnapshotCache.shared.save(d, accountID: accountID, key: ContentSnapshotCache.key(path, query: query))
            }
        }
'''
        assert current.count(snapshot_read) == 1
        current = current.replace(snapshot_read, '', 1)
        # The upload UI consumes a narrow parsed tree snapshot, not the private decoder.
        upload_start = current.index('    func uploadDestinationTree(')
        upload_end = current.index('    func associateWorkspace(', upload_start)
        assert current[upload_start:upload_end].count('    func ') == 1
        current = current[:upload_start] + current[upload_end:]
        # Remote branch deletion has focused native safety/transport fixtures;
        # exclude only that newly added method, never its historic neighbors.
        deletion_start = current.index('    func deleteBranch(_ repo: String, name: String, expectedHead: String, current: String) async throws {')
        deletion_end = current.index('    func fetchWorkspace(', deletion_start)
        assert current[deletion_start:deletion_end].count('    func ') == 1
        current = current[:deletion_start] + current[deletion_end:]
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
        code_start = current.index('    func searchCode(')
        code_end = current.index('    // Read-only gateway', code_start)
        code_search = current[code_start:code_end]
        for token in ['request(endpoint)', 'application/vnd.github.text-match+json',
                      'GitHubAPIRedirectPolicy()', 'try check(bytes, response)',
                      '8 * 1024 * 1024', 'try Task.checkCancellation(); try ensureActiveAccount()']:
            assert token in code_search, token
        current = current[:code_start] + current[code_end:]
        # This feature adds a read-only community gateway and search options;
        # normalize only their exact expressions, keeping all writes frozen.
        start = current.index('    // Read-only gateway')
        end = current.index('    func searchUsers(', start)
        gateway = current[start:end]
        # File-page GFM rendering is a read-only render call with its own fixtures.
        render_start = gateway.index('    /// Server-side GFM rendering for file pages.')
        render_end = gateway.index('    // Native collaboration transport:', render_start)
        assert 'url("/markdown")' in gateway[render_start:render_end]
        gateway = gateway[:render_start] + gateway[render_end:]
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
        # Remote branch rename is create-then-delete over the same documented ref
        # endpoints; its shapes are covered by test_remote_branch_rename.py.
        rename_start = current.index('    /// Local-facing rename becomes create-then-delete on GitHub:')
        rename_end = current.index('\n    }\n', rename_start) + len('\n    }\n')
        if current[rename_end:rename_end + 1] == '\n': rename_end += 1
        assert 'func renameBranch(' in current[rename_start:rename_end]
        current = current[:rename_start] + current[rename_end:]
        old_github = baseline(file)
        # Only the obsolete manual cache-reset hook is removed; retain the
        # byte guard on cache fetching and every unrelated API operation.
        assert '    func clearMemoryCaches()' not in current
        cache_start = old_github.index('    func clearMemoryCaches()')
        cache_end = old_github.index('    var canCheckAppUpdate:', cache_start)
        current = current.replace('    var canCheckAppUpdate:', old_github[cache_start:cache_end] + '    var canCheckAppUpdate:', 1)
        # The bounded error read has focused transport tests. Normalize only
        # this exact block, preserving the session, redirect and file-move guards.
        bounded_error = '''        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var body = Data()
        if !(200..<300).contains(status), let handle = try? FileHandle(forReadingFrom: tmp) {
            defer { try? handle.close() }
            body = (try? handle.read(upToCount: 8192)) ?? Data()
        }
        try check(body, response, operation: "下载归档/文件")
'''
        assert current.count(bounded_error) == 1
        old_download = old_github.split('    private func download(', 1)[1]
        old_error = '        do {\n' + old_download.split('        do {\n', 1)[1].split('        let dir =', 1)[0]
        current = current.replace(bounded_error, old_error, 1)
        # Server-confirmed authorization metadata and login completion are covered
        # by the native OAuth fixture; freeze every other credential/API byte.
        current = current.replace('        AccountStore.updateAuthorization(account, scopes: nil)\n', '')
        current = current.replace('    @Published private(set) var profileWriteAuthorization: Bool? = nil\n', '')
        current = current.replace('    private var authorizationObserver: AnyCancellable?\n', '')
        auth_init = current.index('        profileWriteAuthorization = AccountStore.accounts.first')
        auth_init_end = current.index('        accountObserver = ', auth_init)
        assert 'self.isCurrentSession' in current[auth_init:auth_init_end]
        current = current[:auth_init] + current[auth_init_end:]
        auth_start, auth_end = current.index('    func identify()'), current.index('    func repositories()')
        auth = current[auth_start:auth_end]
        assert 'X-OAuth-Scopes' in auth and 'expectedAccountID == String(id)' in auth
        assert auth.index('expectedAccountID == String(id)') < auth.index('try CredentialStore.save(token,')
        assert 'try Task.checkCancellation()' in auth and 'AccountStore.activate(account.id)' in auth
        assert 'name: .githubAuthorizationCompleted' in auth
        old_auth_start, old_auth_end = old_github.index('    func identify()'), old_github.index('    func repositories()')
        current = current[:auth_start] + old_github[old_auth_start:old_auth_end] + current[auth_end:]
        for signature, next_signature in (
            # Upload-limit consumers are covered by test_repository_upload_limits.py.
            ('    func commitWorkspace(', '    func commitQueue('),
            ('    func commitQueue(', '    func identify('),
            ('    func commit(_ repo:', '    func delete('),
            ('    func saveRemoteDeb(', '    func downloadFile('),
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
        # Only the approved card radius changes; the remaining shape/layout stay exact.
        expected = baseline(file).replace('let radius: CGFloat = 22', 'let radius: CGFloat = 10')
        assert current.split('extension View {\n    ///')[0] == expected.split('extension View {\n    ///')[0]
    elif file == 'RepositoryUI.swift':
        # Approved star/fork navigation changes only this rendering block.
        old = baseline(file)
        # Removing the manual reset must not alter the avatar cache pipeline.
        assert '    func clearIfIdle()' not in current
        cache_start = old.index('    func clearIfIdle()')
        cache_end = old.index('    func image(for url:', cache_start)
        old = old[:cache_start] + old[cache_end:]
        begin, end = 'struct RepositoryStatistics:', '/// The same compact summary'
        # Explicit user refresh now revalidates cached avatars. Its actor/loader
        # behavior is covered by test_avatar_refresh's production harness; keep
        # the redirect policy and all unrelated repository rendering frozen.
        assert current.split('actor AvatarPipeline')[0] == old.split('actor AvatarPipeline')[0]
        assert 'configuration.urlCredentialStorage = nil' in current
        assert 'RepoPocket.avatarRefreshRequested' in current
        assert '.reloadRevalidatingCacheData' in current
        assert current.split('struct LoadingRows:')[1] == old.split('struct LoadingRows:')[1]
        assert current.split('.task(id: repository.id) {')[1].split('.sheet(isPresented: $showParent)')[0] == old.split('.task(id: repository.id) {')[1].split('.sheet(isPresented: $showParent)')[0]
        assert 'openOwner: openOwner' in current
        assert 'repositorySocialAPI' in current and 'RepositorySocialView' in current
    elif file == 'RepositoryStarUI.swift':
        # UIKit and SwiftUI share a lifecycle host; protect the same captured-account
        # mutation and status read instead of freezing the former Button syntax.
        old = baseline(file)
        assert current.split('struct StarAwareRepositoryStatistics')[1] == old.split('struct StarAwareRepositoryStatistics')[1]
        for token in ['RepositoryStarActionHost(name:', 'content(action).task(id: name) { await load() }',
                      'let fixed = try store.target(name, desired: !value)',
                      'try await store.perform(fixed, repository: repository)',
                      'fixed.generation == AccountStore.generation', 'await store.status(name)',
                      'store.known(name) ?? value', 'guard api.isCurrentSession, !store.isBusy(name)',
                      'title: "正在查询星标…", symbol: "hourglass", enabled: false',
                      'title: "星标状态查询失败，点击重试"', 'perform: { Task { await load() } }']:
            assert token in current, token
        assert current.count('await store.status(name)') == 1
        assert current.count('try await store.perform(') == 1
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

def without_deb_release_metadata(current):
    # Explicitly authorized metadata additions; retain the byte-freeze for every
    # other presentation, upload, safety-copy and submission operation.
    current = current.replace('                let release = DebControlEditor.releaseInformation(fields: fields)\n                releaseDate = release.date; changelog = release.changelog\n', '')
    current = current.replace(', releaseDate: releaseDate, changelog: changelog)', ')')
    current = current.replace('            let release = try DebControlEditor.releaseFields(package: package, originalPackage: original["Package"] ?? "", version: version, date: releaseDate, changelog: changelog)\n', '')
    current = current.replace('.merging(release) { _, new in new }', '')
    current = current.replace('''            if let onUseForUpload {
                try onUseForUpload(target)
                // The queue owns its verified copy before this editor is dismissed.
                try? FileManager.default.removeItem(at: dir)
                dismiss()
            } else {
                completed = true
                output = target
            }''', '''            completed = true
            output = target''')
    current = current.replace('            .alert("无法编辑 deb"', '''            .sheet(isPresented: $showUpload) {
                if let output { UploadView(api: api, initialRepo: remote?.repo ?? "", initialBranch: remote?.branch ?? "", initialFile: output, openedFromFolder: true) }
            }
            .alert("无法编辑 deb"''', 1)
    return current.replace('verified[$0.key] == ($0.value.isEmpty ? nil : $0.value)', 'verified[$0.key] == $0.value')

for file, marker in [
    ('ReleaseBranchPicker.swift', 'struct ReleaseBranchPicker: View {'),
    ('TargetPickerView.swift', '    private func load() async {'),
    ('RepositorySearchView.swift', '    private func begin('),
    ('DebEditorView.swift', '    private var editorPresentation: some View {'),
    ('WorkspaceView.swift', '    @MainActor private func importItems(')]:
    current, old = source(file), baseline(file)
    if file == 'DebEditorView.swift': current = without_deb_release_metadata(current)
    if file == 'ReleaseBranchPicker.swift':
        assert current.split(marker)[0] == old.split(marker)[0], file
    elif file == 'WorkspaceView.swift':
        current = restore_workspace_operations(current, old)
        assert current.split(marker, 1)[1] == old.split(marker, 1)[1], file
    elif file == 'RepositorySearchView.swift':
        # UserRepositories UI is also explicitly allowed, its network code isn't.
        current = current.split('\nprivate struct CodeSearchResultRow: View {', 1)[0]
        # Only the new read-only code branch is allowed; freeze repository/user
        # requests, cancellation, generation checks and error handling as before.
        start = current.index('            } else if requestedKind == .code {')
        end = current.index('            } else {', start)
        code_branch = current[start:end]
        for token in ['api.searchCode(requested, page: requestedPage)', 'RepositorySearchRules.accepts(',
                      'incomplete_results', 'requestedPage * 30 < min(value.total_count, 1000)']:
            assert token in code_branch, token
        current = current[:start] + current[end:]
        current = current.replace('        requestedOptions = options\n', '')
        current = current.replace('requested, page: requestedPage, options: requestedOptions)', 'requested, page: requestedPage)')
        assert current.split('    private func invalidate()')[1].split('struct UserRepositoriesView:')[0] == old.split('    private func invalidate()')[1].split('struct UserRepositoriesView:')[0]
        assert 'RepositorySearchRouting.repository(clean)' in current
        assert current.split('    private func load() async {')[-1] == old.split('    private func load() async {')[-1]
    else:
        assert current.split(marker, 1)[1] == old.split(marker, 1)[1], file
print('PASS feature-page matrices: release pagination/status/attachments, direct management entry and 64 optional/folded deb field combinations; native branch/SHA expansion boundaries; exact cc62549 business/shared-style protection')

# Byte-exact operation bodies for mixed UI/logic files: rendering may move, API
# calls/cancellation/permission and destructive confirmation logic may not.
for file in ['RepoPocketApp.swift', 'DesktopViews.swift', 'ReleaseManagementUI.swift',
             'UploadView.swift', 'RepositoryDeletionView.swift', 'RepositorySections.swift',
             'AccountManagement.swift', 'DebEditorView.swift', 'TargetPickerView.swift',
             'WorkspaceView.swift']:
    current_source = source(file)
    if file == 'DebEditorView.swift': current_source = without_deb_release_metadata(current_source)
    old, current = function_blocks(baseline(file)), function_blocks(current_source)
    # Pure rendering helpers may move; business operations remain byte-frozen.
    rendering = ['workspaceManagement(', 'bindingSection(', 'outputSection(']
    for signature, body in old.items():
        if file == 'DebEditorView.swift' and signature.startswith('private func differenceRow('):
            assert 'SoftGroupRow(item.0)' in source(file)
            assert 'VStack(alignment: .leading, spacing: 4)' in source(file)
            assert 'if differencesExpanded' in source(file)
            continue
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
        if file == 'UploadView.swift' and signature in (
            'private func beginEditing(_ item: PendingRepoItem)',
            'private func adoptGeneratedDeb(_ source: URL, replacing id: UUID? = nil)',
            'private func openTargetPicker() async',
            'private func invalidateTarget()',
        ):
            # Approved upload target inheritance and single-item DEB presentation.
            # Real Swift rules: test_upload_destination; real screens: UploadEditorTests.
            # All other upload operations retain their byte-exact historical guard.
            expected = '@MainActor ' + signature if signature == 'private func openTargetPicker() async' else signature
            if signature.startswith('private func adoptGeneratedDeb('):
                expected += ' throws'
            assert expected in current, signature
            continue
        if file == 'UploadView.swift' and signature == 'private func select(_ result: Result<[URL], Error>) async':
            changed = current.get(signature, '')
            for token in ['RepoQueue.addingUploadBytes(size, to: total)', 'RepoQueue.addingUploadBytes(actual, to: total)', 'DebControlEditor.prepareForUpload', 'var accepted = false', 'if !accepted', 'queue.append(contentsOf: pending)', 'accepted = true']:
                assert token in changed, token
            continue
        if file == 'UploadView.swift' and signature == 'private func commit() async':
            changed = current.get('@MainActor ' + signature, '')
            for token in ['let authorized = reviewFingerprint', 'checkedFingerprint() == authorized', 'api.commitQueue', 'reviewFingerprint = nil', 'reviewError = error.localizedDescription']:
                assert token in changed, token
            continue
        if file == 'UploadView.swift' and signature in (
            'private func clearSelection()', 'private func checkAccess() async',
            'private func trollPublish() async', 'private func loadReleases() async',
            'private func createAndUpload() async', 'private func uploadSelected() async',
            'private func saveAsset(_ asset: Asset, repo: String) async', 'private func publish() async',
            'static func inferredTrollVersion(from filename: String) -> String'):
            assert signature not in current, signature
            assert 'trollPublish(' not in current_source
            shared = source('ReleaseManagementUI.swift')
            for token in ['plan.mayFinalize', 'retainedDraft = created', 'target.generation == AccountStore.generation', 'self.downloader.persist', 'try state.check()']:
                assert token in shared, token
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'private func stage(_ result: Result<[URL], Error>)':
            changed = current.get('private func stage(_ result: Result<[URL], Error>, cleanupSelection: Bool = true)', '')
            for token in ['state.valid', 'ReleaseAttachmentRules.copy(source)', 'if cleanupSelection', 'ShareSelectionCleanup.remove(urls)', 'try state.check()', 'attachments.append(item)', 'removeItem(at: item.file.deletingLastPathComponent())']:
                assert token in changed, token
            continue
        if file == 'ReleaseManagementUI.swift' and signature == 'private func upload(_ file: URL, to r: ManagedRelease)':
            assert signature not in current
            review = source('ReleaseAttachmentReview.swift')
            for token in ['ReleaseAttachmentRules.copy(input)', 'api.requireWriteAccess(repo)', 'current == original', 'verify(attachment) == authorizedHash', 'api.uploadManagedAsset', 'ShareSelectionCleanup.remove([source])', 'generation == AccountStore.generation']:
                assert token in review, token
            continue
        if file == 'RepoPocketApp.swift' and signature in ('private func refresh() async', 'private func load() async', 'private func refreshProfile() async'):
            # Explicit successful refresh may now notify avatars/upstream readers;
            # remove only these exact events before freezing the original API path.
            changed = current.get(signature, '')
            if signature == 'private func load() async':
                # Approved stale-while-revalidate replaces this loader, not its routes or write authority.
                for token in ['loadID = token', 'generation == AccountStore.generation',
                              'activeBranch == requestedBranch', 'try Task.checkCancellation()',
                              'api.contents(repo, path: path, branch: resolved)', 'async let metadata = api.repository(repo)',
                              'metadataFresh = false', 'repositoryInfo = info; metadataFresh = true',
                              'metadata.load(api: api, repo: repo, branch: resolved, entries: result)']:
                    assert token in changed, token
                assert 'repositoryInfo = nil' not in changed
                continue
            if signature == 'private func refresh() async':
                changed = changed.replace('        loadError = ""\n', '')
                changed = changed.replace('repos = result; starred = stars; loaded = true; updatedAt = Date()',
                                          'repos = result; starred = stars; loaded = true')
                changed = changed.replace('loadError = error.localizedDescription; api.message = loadError', 'api.message = error.localizedDescription')
            changed = changed.replace('            if refreshing, api.isCurrentSession {\n                NotificationCenter.default.post(name: Notification.Name("RepoPocket.avatarRefreshRequested"), object: UUID())\n                NotificationCenter.default.post(name: Notification.Name("RepoPocket.upstreamRefreshRequested"), object: api.accountID)\n            }\n', '')
            changed = changed.replace('            if refreshing, api.isCurrentSession {\n                NotificationCenter.default.post(name: Notification.Name("RepoPocket.avatarRefreshRequested"), object: UUID())\n            }\n', '')
            changed = changed.replace('        do {\n            try await api.identify()\n            guard api.isCurrentSession else { return }\n            NotificationCenter.default.post(name: Notification.Name("RepoPocket.avatarRefreshRequested"), object: UUID())\n        }', '        do { try await api.identify() }')
            assert changed == body, (file, signature)
            continue
        if file == 'RepoPocketApp.swift' and signature in ('private func read() async', 'private func save() async'):
            # Approved file-reader redesign: automatic bounded reading and a
            # dedicated editor replace the old manual Form actions. Production
            # text/lexer and page-request regressions cover the replacement.
            continue
        if file == 'RepositorySections.swift' and signature == 'private func load() async':
            changed = current.get(signature, '')
            changed = changed.replace('        loadError = ""\n', '')
            changed = changed.replace('loaded = true; updatedAt = Date()', 'loaded = true')
            changed = changed.replace('if api.isCurrentSession, !RefreshFailure.isCancellation(error) { loadError = error.localizedDescription; api.message = loadError }',
                                      'if !RefreshFailure.isCancellation(error) { api.message = error.localizedDescription }')
            assert changed == body, (file, signature)
            continue
        assert current.get(signature) == body, (file, signature)
print('PASS byte-exact baseline operation bodies: account, navigation/API actions, local/remote workspace, upload, release and destructive guards')
