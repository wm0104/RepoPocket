"""Inline native List rows preserve swipe; stable end caps suppress path morphs."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ui = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
sections = Path(REPO_ROOT, 'RepoPocket/RepositorySections.swift').read_text()
style = Path(REPO_ROOT, 'RepoPocket/WorkspaceSelectionUI.swift').read_text()
home = ui.split('struct RepositoriesView:', 1)[1].split('struct BrowserView:', 1)[0]
settings = ui.split('struct SettingsView:', 1)[1]
assert home.count('RepositoryHomeLinksSection(api:') == 1
assert 'ownedExpanded' not in home and 'starredExpanded' not in home
assert 'home-collection-' in sections
assert 'RepositoryCollectionView(api: api, section: .owned)' not in settings
assert 'RepositoryCollectionView(api: api, section: .starred)' not in settings
# Settings keeps five groups: account card, security, general, storage, about.
for title in ['账号与安全', '通用', '关于']:
    assert title in settings, title
assert 'Token 仅保存在本机钥匙串，切换账号自动隔离' in settings
assert 'RepoPocket ' in settings
assert 'SoftGroupRows {' in sections
assert 'ListSearchButton(' in sections
assert 'bottom: repository.id == filteredRepositories.last?.id' in sections
assert 'Color.clear.frame(height: 8)' not in sections
assert 'ForEach(filteredRepositories)' in sections
assert 'BrowserView(api: api' in sections
assert '.swipeActions(edge: .trailing, allowsFullSwipe: false)' in sections
assert 'api.starredRepositories()' in sections
assert 'api.fork(repository.full_name)' in sections
assert 'RoundedRectangle(cornerRadius: radius, style: .continuous)' in style
assert 'let radius: CGFloat = 22' in style
for forbidden in ['withAnimation', 'DisclosureGroup', 'RepositorySectionContainer', 'List { List']:
    assert forbidden not in sections
assert 'Section("直接打开仓库")' not in home
assert 'Image(systemName: "plus")' in home
assert 'Image(systemName: "magnifyingglass")' in home
assert 'Button("打开仓库")' in home
print('PASS inline sibling rows, native swipe, real terminal-row 22pt corners, no synthetic footer, no morph animations, settings navigation; device appearance unverified')
