"""Foreground is inert; scans only first-load/manual/actual operations."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
w=Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
a=Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
for source in Path(REPO_ROOT, 'RepoPocket').glob('*.swift'):
    s=source.read_text()
    for forbidden in ['scenePhase', 'willEnterForegroundNotification', 'didBecomeActiveNotification']:
        assert forbidden not in s, source
assert '.onAppear' not in w
assert '.task { if !hasScanned' in w and '.refreshable { await scan() }' in w
assert 'Button("刷新变更") { Task { await scan() } }.disabled(busy)' in w
assert '.transition(' not in w and '.animation(' not in w
assert '.disabled(busy || binding == nil)' in w  # no weakening association safety
assert '本地新增、修改、删除均可先勾选' in w
assert '.disabled(busy || commitBlockReason != nil)' in w
assert 'ProgressView("处理中，请保持前台…").softGroupedRow()' in w
assert '.overlay' not in w and '.allowsHitTesting(false)' not in w
assert 'focusedField = nil' in w and '.id(request.id)' in w
assert '.id(accountID)' in a and 'githubAccountChanged' in a
scan=w.split('@MainActor private func scan()',1)[1].split('struct LocalDiffView',1)[0]
assert 'guard !busy else { return }' in scan
assert scan.index('generation == AccountStore.generation') < scan.index('roots = result.0')
assert scan.index('folder == requestedFolder') < scan.index('roots = result.0')
assert scan.index('roots = result.0') < scan.index('reconcileWorkspaces(') < scan.index('scanSucceeded(')
assert 'Task.checkCancellation()' in scan and 'before.hashes == after.hashes' in scan
for signature in ['importItems(_ urls: [URL], zip: Bool)', 'downloadRemote()', 'associate(_ folder: URL)', 'checkRemote()', 'applyResolvedPull()', 'commit()']:
    body=w.split('@MainActor private func '+signature,1)[1].split('@MainActor private func',1)[0]
    assert '!busy' in body.split('busy = true',1)[0], signature
assert 'hasScanned = true' in scan  # no foreground reset/recreation identity
import re
build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', Path(REPO_ROOT, "project.yml").read_text()).group(1)
assert build == '1.1.2'
assert f'CFBundleVersion\' "$APP/Info.plist")" = "{build}"' in Path(REPO_ROOT, ".github/workflows/build.yml").read_text()
print('PASS manual-only foreground contract, stable Text, explicit safety reason, no blocking overlay, atomic scan/reconciliation, operation busy gates and internal build12')
