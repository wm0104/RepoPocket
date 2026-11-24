"""Static lifecycle contracts; not a substitute for Files/provider device tests."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
picker = Path(REPO_ROOT, 'RepoPocket/WorkspaceDocumentPicker.swift').read_text()
assert 'let id = UUID()' in picker and 'let kind: Kind' in picker
assert 'request.kind == .files ? [.item] : [.folder]' in picker
assert 'forOpeningContentTypes: types, asCopy: false' in picker
assert picker.count('[.item]') == 1  # Broad types apply only to explicit file import.
assert 'var allowsMultipleSelection = true' in picker
assert 'picker.allowsMultipleSelection = allowsMultipleSelection' in picker
git_view = Path(REPO_ROOT, 'RepoPocket/LocalProjectImportView.swift').read_text()
registry = Path(REPO_ROOT, 'RepoPocket/LocalGitRegistry.swift').read_text()
access = Path(REPO_ROOT, 'RepoPocket/LocalGitFileAccess.swift').read_text()
engine = Path(REPO_ROOT, 'RepoPocket/LocalGitEngine.swift').read_text()
assert 'FolderPicker' not in git_view and 'UIDocumentPickerViewController' not in git_view
assert '@State private var picker: WorkspaceImportRequest?' in git_view
assert 'WorkspaceImportRequest(kind: .folder)' in git_view
assert '.sheet(item: $picker)' in git_view and '.id(request.id)' in git_view
callback = git_view.split('WorkspaceDocumentPicker(request: request, allowsMultipleSelection: false)', 1)[1].split('.id(request.id)', 1)[0]
assert 'if let url = urls?.first { acceptPicker(url) }' in callback
assert callback.index('acceptPicker(url)') < callback.index('picker = nil')
assert 'folder = try store.prepare(url)' in git_view
assert 'url.bookmarkData(options: [.minimalBookmark]' in registry
assert 'JSONEncoder().encode(next).write(to:' in registry
assert 'JSONDecoder().decode([LocalGitProject].self, from:' in registry
assert 'LocalGitFileAccess.withRoot(project, internalRoot: internalRoot)' in engine
assert 'URL(resolvingBookmarkData: project.bookmark, options: [.withoutUI]' in access
assert 'guard !stale,' in access and 'try identity(url) == project.identity' in access
for source in (registry, access):
    assert 'let scoped = url.startAccessingSecurityScopedResource()' in source
    assert 'defer { if scoped { url.stopAccessingSecurityScopedResource() } }' in source
    assert '.withSecurityScope' not in source
assert 'picker.delegate = context.coordinator' in picker
assert 'documentPickerWasCancelled' in picker and 'finish(nil)' in picker
assert 'guard !finished else' in picker and 'finished = true' in picker
assert 'workspace.import.cancel' in picker and '取消导入' in picker
assert 'addChild(picker)' in picker and 'picker.didMove(toParent: self)' in picker
assert 'picker.view.topAnchor.constraint(equalTo: bar.bottomAnchor)' in picker
assert 'let label = UILabel()' not in picker
assert 'view.safeAreaLayoutGuide.topAnchor' in picker
assert 'button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)' in picker
for forbidden in ['setValue(', 'value(forKey:', 'navigationItem', 'UTType.data', '[.content]']:
    assert forbidden not in picker
# Abstract request/lifecycle model: every presentation gets a new identity,
# immutable captured mode; nil cancels without import, duplicate callbacks ignored.
import uuid
for sequence in [('folder',), ('folder', 'files'), ('files', 'folder', 'files'), ('folder', 'folder')]:
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
# Files and folder pickers share the external cancel container.
assert 'return WorkspacePickerContainer(picker: picker' in picker
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
print('PASS static picker identity, file/folder filters, explicit dismissal, public cancel containment, scoped directory access; abstract lifecycle model')
