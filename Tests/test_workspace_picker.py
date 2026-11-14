"""Static lifecycle contracts; not a substitute for Files/provider device tests."""
from pathlib import Path
import re

REPO_ROOT = Path(__file__).resolve().parents[1]
picker = Path(REPO_ROOT, 'RepoPocket/WorkspaceDocumentPicker.swift').read_text()
view = Path(REPO_ROOT, 'RepoPocket/WorkspaceView.swift').read_text()
assert 'let id = UUID()' in picker and 'let kind: Kind' in picker
assert '@State private var importRequest: WorkspaceImportRequest?' in view
assert '.sheet(item: $importRequest)' in view and '.id(request.id)' in view
assert 'WorkspaceImportRequest(kind: .zip)' in view
assert 'WorkspaceImportRequest(kind: .folder)' in view
assert 'zip = true' not in view and 'zip = false' not in view
assert 'zip: request.isZIP' in view
assert re.search(r'importRequest = nil\n[ \t]+guard let urls else', view)
assert 'request.kind == .files ? [.item] : (request.isZIP ? [.zip] : [.folder])' in picker
assert 'forOpeningContentTypes: types, asCopy: false' in picker
assert picker.count('[.item]') == 1  # Broad types apply only to explicit file import.
assert 'var allowsMultipleSelection = true' in picker
assert 'picker.allowsMultipleSelection = allowsMultipleSelection' in picker
git_view = Path(REPO_ROOT, 'RepoPocket/GitWorkspaceView.swift').read_text()
core = Path(REPO_ROOT, 'RepoPocket/GitCore.swift').read_text()
assert 'FolderPicker' not in git_view and 'UIDocumentPickerViewController' not in git_view
assert '.sheet(item: $importRequest)' in git_view and '.id(request.id)' in git_view
assert 'WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false)' in git_view
assert 'importRequest = nil\n                    guard let url = urls?.first else { return }' in git_view
assert 'try gitCore.importRepository(url)' in git_view
for required in ('restoreBookmarks()', 'persistBookmarks()', 'startAccessingSecurityScopedResource()', 'stopAccessingSecurityScopedResource()', 'bookmarkData(options: []', 'URL(resolvingBookmarkData: bookmark, options: []'):
    assert required in core
assert 'withSecurityScope]' not in core
assert 'picker.delegate = context.coordinator' in picker
assert 'documentPickerWasCancelled' in picker and 'finish(nil)' in picker
assert 'guard !finished else' in picker and 'finished = true' in picker
assert 'workspace.import.cancel' in picker and '取消导入' in picker
assert 'addChild(picker)' in picker and 'picker.didMove(toParent: self)' in picker
assert 'picker.view.topAnchor.constraint(equalTo: showCancel ? bar.bottomAnchor : view.safeAreaLayoutGuide.topAnchor)' in picker
assert 'showCancel: !request.isZIP' in picker
assert 'let label = UILabel()' not in picker
assert 'view.safeAreaLayoutGuide.topAnchor' in picker
assert 'button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)' in picker
for forbidden in ['setValue(', 'value(forKey:', 'navigationItem', 'UTType.data', '[.content]']:
    assert forbidden not in picker
assert 'source.startAccessingSecurityScopedResource()' in view
assert 'source.stopAccessingSecurityScopedResource()' in view
assert 'NSFileCoordinator().coordinate' in view
assert 'values.isRegularFile == true, values.isSymbolicLink != true' in view
assert 'WorkspaceZIP.extract(readable, to: stage)' in view
# Abstract request/lifecycle model: every presentation gets a new identity,
# immutable captured mode; nil cancels without import, duplicate callbacks ignored.
import uuid
for sequence in [('zip',), ('folder', 'zip'), ('zip', 'folder', 'zip'), ('zip', 'zip'), ('files',), ('folder', 'files', 'zip')]:
    identities = set()
    for kind in sequence:
        identity = uuid.uuid4(); assert identity not in identities; identities.add(identity)
        for events in [(None, ['file']), (['file'], None), (['file'], ['file'])]:
            finished = False; imports = []
            for urls in events:
                if finished: continue
                finished = True
                if urls is not None: imports.append((kind, urls))
            assert len(imports) == (0 if events[0] is None else 1)
            assert not imports or imports[0][0] == kind
# Both folder and ZIP entry points must use the shared external cancel container.
assert 'return WorkspacePickerContainer(picker: picker' in picker
assert view.count('WorkspaceDocumentPicker(request: request)') == 1
assert 'UIDocumentPickerViewController' not in view
# Simulate providers at arbitrary directory depth: app cancel does not pop Files
# navigation, and duplicate delegate cancel callbacks cannot import anything.
for depth in (0, 1, 2, 10, 100):
    finished = False
    completions = []
    for event in (None, None, ['late-provider-selection']):
        if finished:
            continue
        finished = True
        completions.append(event)
    assert completions == [None], depth
print('PASS static picker identity, ZIP-only filter, explicit dismissal, public cancel containment, scoped/coordinated strict extraction; abstract lifecycle model')
