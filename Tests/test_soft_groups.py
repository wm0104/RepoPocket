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
assert '.overlay(alignment: .bottom)' in style
assert '.fill(Color(uiColor: .separator))' in style
assert 'GitHubAvatar(url: avatarURL, size: 24)' in card
assert 'cornerRadius: radius, style: .continuous' in style and 'let radius: CGFloat = 22' in style
assert 'listRowBackground(' in style and 'SoftGroupShape' in style and '.secondarySystemGroupedBackground' in style
# Only the decoration is clipped; never clip the interactive List or its content.
assert style.count('.clipShape(') == 1
assert '.appearance()' not in style and '.blur(' not in style
for text in [ui, workspace, upload, detail]:
    assert '.softGroupedRow(top: true)' in text
    assert '.softGroupedRow(bottom: true)' in text
section = ui.split('RepositoryInlineSection(api: api, section: .owned', 1)[1].split('.listStyle(.insetGrouped)', 1)[0]
assert 'DisclosureGroup' not in section and 'repositoriesExpanded' not in ui
assert 'softGroupedRow' not in section
assert 'refresh()' not in section and 'repos = []' not in section
assert 'NavigationLink("添加 / 更新 GitHub 账号")' in Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text()
assert 'Section("已保存账号")' not in ui
assert '.sheet(isPresented: $accountPresentation.showing' in ui
assert '.listStyle(.insetGrouped)' in workspace and '.listStyle(.insetGrouped)' in ui
assert '.formStyle(.grouped)' in upload
assert '.swipeActions {' in workspace and 'pendingDelete = root; confirmDelete = true' in workspace
assert '.swipeActions' in ui and 'confirmDelete' in ui
assert 'verticalSizeClass == .compact ? 3 : 7' in card
assert '.lineLimit(descriptionLineLimit)' in card
# Divider regression: screenshot paths must decorate all intermediate rows.
assert 'Section("直接打开仓库")' not in ui
assert '.sheet(isPresented: $showOpen)' in ui
assert 'NavigationLink("浏览")' in ui
assert '.softGroupedRow().softGroupedRow' not in ui + workspace + upload
assert ui.count('top: e.id == entries.first?.id, bottom: e.id == entries.last?.id') == 3
assert 'if busy { ProgressView() }' in ui
for marker in ['Button("导入一个或多个文件夹")', 'Button("导入一个或多个 ZIP")',
               'Text(binding.repo + " · " + binding.branch)', 'TextField("提交说明", text: $commitMessage)']:
    row = next(line for line in workspace.splitlines() if marker in line)
    assert '.softGroupedRow()' in row, row
for marker in ['LabeledContent("目录",', 'Text(r.draft ?', 'Text("附件："',
               'Button("公开此 Release")', 'ShareLink("分享下载链接"',
               'Button("上传到已选中的 Release / 重试")', 'Button("检查提交权限")']:
    row = next(line for line in upload.splitlines() if marker in line)
    assert '.softGroupedRow()' in row, row
assert 'bottom: local == nil' in upload
assert 'bottom: !(bytes > 10 * 1024 * 1024 && mode == 0)' in upload
assert 'bottom: release == nil' in upload
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
print('PASS divider regression: settings, upload, local directory, workspace detail; conditional last-row corners')
print('PASS soft grouped UI contracts: equal-width repositories, 22pt continuous row backgrounds, native lists/swipe deletion, semantic colors and adaptive text')
