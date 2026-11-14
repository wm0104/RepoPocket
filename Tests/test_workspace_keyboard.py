"""Source contracts are not substitutes for true-device keyboard testing."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
w = Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
assert '@FocusState private var focusedField: Field?' in w
for name in ['remoteRepo', 'remoteBranch', 'associationRepo', 'associationBranch', 'baselineRevision', 'commitMessage']:
    assert f'.focused($focusedField, equals: .{name})' in w
assert w.count('.focused($focusedField, equals:') == 6
assert '.onSubmit { focusedField = nil }' in w
assert 'Button("完成") { focusedField = nil }' in w
assert '.scrollDismissesKeyboard(.interactively)' in w
assert '.onChange(of: importRequest?.id) { _ in focusedField = nil }' in w
assert '.onChange(of: folder) { _ in focusedField = nil }' in w
assert '.onDisappear { focusedField = nil }' in w
assert 'commitMessageFocused' not in w
assert 'Button("验证副本并关联当前远端") { focusedField = nil; Task' in w
for line in w.splitlines():
    if '.onSubmit' in line or 'Button("完成")' in line:
        assert 'Task' not in line and 'commit()' not in line and 'associate(' not in line
print('PASS source contracts: 6 unique focus targets, Done only clears focus, picker/folder/disappear reset; no backend action on submit')
