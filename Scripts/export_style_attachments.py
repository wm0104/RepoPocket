"""Export native UI regression screenshots from xcresult bundles."""
import json
from pathlib import Path
import subprocess
import sys

bundle, output = sys.argv[1:3]
scope = sys.argv[3] if len(sys.argv) > 3 else 'all'
destination = Path(output)
destination.mkdir(parents=True, exist_ok=True)
pending = [None]
seen = set()
exported = set()
expected = {'swipe-first', 'swipe-middle', 'swipe-last', 'readme-badges'}
expected.update({'release-compact-attachments', 'release-inline-progress', 'repository-owner-profile'})
expected.update({'issue-delete-confirmation-home-issue-4', 'issue-delete-confirmation-repository-issue-4',
                 'issue-delete-confirmation-personal-issue-4'})
expected.update({'account-connections-home', 'account-followers-list', 'account-following-user-profile',
                 'home-owned-destination', 'home-grouped-navigation', 'issue-quoted-reply', 'activity-daily-calendar'})
expected.update({'workflow-step-output', 'local-folder-selection', 'long-patch-leading', 'local-import-picker', 'recorded-patch-leading'})
expected.update({'local-deb-editor', 'local-whole-folder-import'})
expected.update({'account-session-after-switch', 'local-delete-confirmation', 'local-import-destination'})
expected.update({'local-history-collapsed', 'local-history-expanded', 'local-commit-detail',
                 'local-commit-patch', 'local-history-after-folding'})
expected.update({'source-preview-left', 'source-preview-right', 'source-editor-left', 'source-editor-right'})
expected.update({'patch-highlight-left', 'patch-highlight-right', 'patch-raw-left', 'patch-raw-right'})
profiles = {'profile-issue-list', 'profile-fork', 'profile-activity', 'profile-fork-repository', 'profile-activity-repository'}
profiles.update({'profile-public-contacts', 'profile-contacts-retry'})
profiles.update({'social-accounts-managed', 'social-accounts-permission', 'social-accounts-long-press'})
actions = {'release-compact-attachments', 'release-inline-progress', 'profile-following-action', 'profile-follow-status-error', 'repository-owner-profile'}
actions.update({'workflow-runs-normal', 'workflow-runs-selection', 'workflow-runs-partial-failure'})
file_feedback = {'repository-zip-completion', 'local-project-files-long-press', 'local-deb-editor'}
download_lifecycle = file_feedback | {'local-file-sheet-dismissed', 'release-compact-attachments', 'release-inline-progress'}
file_edit = {'remote-file-editor-cancelled', 'source-preview-left', 'source-preview-right', 'source-editor-left', 'source-editor-right'}
file_edit.update({'mobile-editor-saved-preview', 'source-native-file-search', 'repository-file-folder-search', 'repository-search-opened-code'})
diagnostics = {'account-switch-failure', 'account-control-failure'}
diagnostics.update({'mobile-editor-create-menu', 'source-native-find-start'})
maintenance = {'local-project-compact', 'local-project-information', 'local-branch-create-confirmation',
               'local-history-collapsed', 'local-history-expanded', 'local-commit-detail',
               'local-commit-patch', 'local-history-after-folding', 'local-import-destination',
               'local-import-picker', 'local-whole-folder-import', 'local-folder-selection',
               'upstream-watch-link-input-responsive', 'upstream-preview-retains-result',
               'upstream-preview-retains-error', 'workflow-run-details-collapsed',
               'workflow-run-details-after-rapid-folding', 'repository-more-after-rapid-folding',
               'workflow-runs-normal', 'workflow-runs-selection', 'workflow-runs-partial-failure'}
maintenance.update('upstream-preview-collapsed-' + mode for mode in ('empty', 'single', 'many', 'truncated'))
maintenance.update(prefix + mode for prefix in ('upstream-commits-expanded-', 'upstream-files-expanded-')
                   for mode in ('single', 'many', 'truncated'))
branch_merge = {'local-branch-merge-preview', 'remote-branch-merge-preview',
                'remote-branch-squash-confirm', 'remote-branch-squash-result'}
release_editor = {'release-editor-filled', 'release-editor-inbox', 'release-editor-attached',
                  'release-editor-scrolled', 'release-editor-confirmation',
                  'release-editor-account-changed', 'release-editor-denied'}
if scope == 'release-editor':
    expected = release_editor
elif scope == 'branch-merge':
    expected = branch_merge
elif scope == 'profiles':
    expected = profiles
elif scope == 'workflow-selection':
    expected = {'workflow-runs-normal', 'workflow-runs-selection', 'workflow-runs-partial-failure'}
elif scope == 'actions':
    expected = actions
elif scope == 'file-feedback':
    expected = file_feedback
elif scope == 'download-lifecycle':
    expected = download_lifecycle
elif scope == 'file-edit':
    expected = file_edit
elif scope == 'review-regressions':
    expected = {'account-session-after-switch', 'local-deb-editor', 'profile-public-contacts',
                'profile-contacts-retry', 'readme-badges'}
elif scope == 'maintenance-regressions':
    expected = maintenance
elif scope == 'all':
    expected.update(release_editor)
    expected.update(branch_merge)
    expected.update(profiles)
    expected.update(actions)
    expected.update(file_feedback)
    expected.update(download_lifecycle)
    expected.update(file_edit)
    expected.update(maintenance)
else:
    raise ValueError('Unknown UI test scope')

while pending:
    reference = pending.pop()
    if reference in seen:
        continue
    seen.add(reference)
    command = ['xcrun', 'xcresulttool', 'get', 'object', '--legacy', '--path', bundle, '--format', 'json']
    if reference:
        command += ['--id', reference]
    tree = json.loads(subprocess.check_output(command))
    stack = [tree]
    while stack:
        item = stack.pop()
        if isinstance(item, list):
            stack.extend(item)
        elif isinstance(item, dict):
            for key in ['testsRef', 'summaryRef']:
                ref = item.get(key, {}).get('id', {}).get('_value')
                if ref:
                    pending.append(ref)
            name = item.get('name', {}).get('_value', '')
            payload = item.get('payloadRef', {}).get('id', {}).get('_value')
            if payload and name in expected | diagnostics:
                subprocess.run(['xcrun', 'xcresulttool', 'export', 'object', '--legacy', '--type', 'file', '--path', bundle,
                                '--id', payload, '--output-path', str(destination / (name + '.png'))], check=True)
                if name in expected:
                    exported.add(name)
            stack.extend(item.values())

if exported != expected:
    raise RuntimeError(f'Expected native UI regression screenshots; got {exported}')
print('PASS exported native swipe, README, local commit, folding and source scrolling screenshots')
