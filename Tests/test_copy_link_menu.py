"""Guard the copy-link entry points added for the Coolapk feedback.

Cases: file link, file raw link, folder link, and the rule that copy-link rows live in the
long-press menus only — the browser and file toolbar menus no longer duplicate them.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
RULES = (ROOT / 'RepoPocket/RepositoryLinkRules.swift').read_text(encoding='utf-8')

BROWSER = APP.split('struct BrowserView: View {', 1)[1].split('struct FileView: View {', 1)[0]
FILE = APP.split('struct FileView: View {', 1)[1].split('\nstruct ', 1)[0]
ROWS = BROWSER.split('@SoftGroupRowsBuilder private var directoryRows:', 1)[1].split('var body: some View {', 1)[0]

# Toolbar menus keep only the repository link; the per-file and per-folder copies are long-press.
assert BROWSER.count('.toolbar {') == 1
browser_toolbar = BROWSER.split('.toolbar {', 1)[1]
assert 'title: "复制仓库链接"' in browser_toolbar
assert 'perform: { copyFeedback.copy(repo) }' in browser_toolbar
assert 'title: "刷新目录"' in browser_toolbar
for removed in ('复制当前目录链接', 'directoryLink', 'folder: true'):
    assert removed not in browser_toolbar, removed

MAIN_FILE = FILE.split('private var fileInformation', 1)[0]
assert MAIN_FILE.count('.toolbar {') == 1
file_toolbar = MAIN_FILE.split('.toolbar {', 1)[1]
assert 'NativeActionMenu(title: "文件操作", items: fileMenuItems)' in file_toolbar
file_actions = FILE.split('private var fileMenuItems: [NativeMenuItem]', 1)[1].split('var body: some View', 1)[0]
assert 'NativeMenuItem(id: "info", title: "文件信息"' in file_actions
for removed in ('复制文件链接', '复制 raw 链接', 'copyFeedback', 'RepositoryCopyFeedback'):
    assert removed not in FILE, removed
assert 'RepositoryCopyFeedback()' not in FILE
assert '.repositoryCopyNotice(' not in FILE

# Long-press: file rows copy the blob link, the raw link and (with write access) delete.
file_menu = ROWS.split('} else if e.type == "file"', 1)[1].split('.contextMenu {', 1)[1]
assert 'Label("复制文件链接"' in file_menu
assert 'RepositoryLinkRules.contentURL(repo, branch: activeBranch, path: e.path)' in file_menu
assert 'Label("复制 raw 链接"' in file_menu
assert 'raw: true' in file_menu
assert 'if canWrite { Button("删除", role: .destructive)' in file_menu

# Long-press: folder rows copy the tree link only, and never a raw link.
folder_menu = ROWS.split('if e.type == "dir"', 1)[1].split('} else if e.type == "file"', 1)[0]
assert 'Label("复制文件夹链接"' in folder_menu
assert 'folder: true' in folder_menu.split('contentURL(', 1)[1]
assert 'raw: true' not in folder_menu
assert folder_menu.count('Button {') == 1
assert BROWSER.count('.contextMenu {') == 2

# One shared builder: blob/tree and raw hosts live in the rules file only.
assert 'static func contentURL(' in RULES
assert 'blob' in RULES and 'tree' in RULES
assert 'raw.githubusercontent.com' in RULES
for stray in ('github.com/" + repo', 'raw.githubusercontent.com/" + repo', 'github.com/', 'raw.githubusercontent.com'):
    assert stray not in APP, stray

print('PASS copy-link: long-press only for file, raw and folder links; toolbar menus no longer duplicate')
