"""Remote workspaces stay inert; local Git may recheck external edits on return."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
a=Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
for source in Path(REPO_ROOT, 'RepoPocket').glob('*.swift'):
    s=source.read_text()
    for forbidden in ['willEnterForegroundNotification', 'didBecomeActiveNotification']:
        assert forbidden not in s, source
    # Visible Git and Actions status views may recheck; never mutate on return.
    assert ('scenePhase' in s) == (source.name in ('RepoPocketApp.swift', 'WorkflowViews.swift', 'LocalProjectView.swift', 'LocalGitStageView.swift', 'CollaborationViews.swift')), source
    if source.name == 'CollaborationViews.swift':
        status = s.split('struct RepositoryWorkflowStatus:', 1)[1].split('struct CollaborationListView:', 1)[0]
        assert '.task(id: scenePhase)' in status and 'guard scenePhase == .active' in status
        assert 'while !Task.isCancelled, api.isCurrentSession' in status
        assert 'api.latestRepositoryWorkflowRun(repo)' in status
        assert 'communityMutation(' not in status and 'scan()' not in status
    if source.name == 'LocalGitStageView.swift':
        foreground = s.split('.onChange(of: scenePhase)', 1)[1].split('.refreshable', 1)[0]
        assert 'if phase == .active, valid, !busy { refresh() }' in foreground
        assert 'task?.cancel(); snapshot = nil; confirming = false' in foreground
        assert 'mutate(' not in foreground
        load = s.split('@MainActor private func load()', 1)[1].split('private func mutate(', 1)[0]
        assert 'LocalGitEngine.shared.run("stageStatus"' in load
        assert 'Task.checkCancellation()' in load and 'if valid { snapshot = value }' in load
        assert 'commitStaged' not in load and 'sync(' not in load
    if source.name == 'LocalProjectView.swift':
        refresh = s.split('private func refreshExternalChanges()', 1)[1].split('private func check(', 1)[0]
        for guard in ('externalRefreshPending', 'visible', 'scenePhase == .active', '!busy', 'sheet == nil', '!pendingCommit', 'syncing == nil', 'valid'):
            assert guard in refresh, guard
        assert 'await check(force: true)' in refresh
        assert 'sync(' not in refresh and 'configureRemote' not in refresh
    if source.name == 'WorkflowViews.swift':
        assert s.split('struct WorkflowRunView:', 1)[1].count('scenePhase') == 4
        assert '@Environment(\\.scenePhase) private var scenePhase' in s
        polling = s.split('.task(id: cancellation.waiting && scenePhase == .active) {', 1)[1].split('        .task {', 1)[0]
        assert 'guard cancellation.waiting, scenePhase == .active' in polling
        assert 'for _ in 0..<60' in polling and 'Task.sleep(nanoseconds: 5_000_000_000)' in polling
        assert 'try Task.checkCancellation()' in polling and 'await refreshRunStatus()' in polling
        assert 'scan()' not in polling and 'communityMutation(' not in polling
foreground=a.split('.onChange(of: scenePhase)', 1)[1].split('.task { await NetworkWarmup', 1)[0]
assert foreground.count('appEntryCheck(api: api)') == 1
for inert in ('scan()', 'refresh', 'load('):
    assert inert not in foreground, inert
assert '.id(accountID)' in a and 'githubAccountChanged' in a
import re
build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', Path(REPO_ROOT, "project.yml").read_text()).group(1)
assert re.fullmatch(r'\d+\.\d+\.\d+', build)
assert 'CFBundleVersion\' "$APP/Info.plist")" = "$APP_VERSION"' in Path(REPO_ROOT, ".github/workflows/build.yml").read_text()
print('PASS guarded local Git foreground recheck, account change handling and idle repository views')
