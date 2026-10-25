"""Export native UI regression screenshots from Xcode 15."""
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
actions = {'release-compact-attachments', 'release-inline-progress', 'profile-following-action', 'profile-follow-status-error', 'repository-owner-profile'}
actions.update({'workflow-runs-normal', 'workflow-runs-selection', 'workflow-runs-partial-failure'})
file_feedback = {'repository-zip-completion', 'local-project-files-long-press', 'local-deb-editor'}
download_lifecycle = file_feedback | {'local-file-sheet-dismissed', 'release-compact-attachments', 'release-inline-progress'}
if scope == 'profiles':
    expected = profiles
elif scope == 'actions':
    expected = actions
elif scope == 'file-feedback':
    expected = file_feedback
elif scope == 'download-lifecycle':
    expected = download_lifecycle
elif scope == 'all':
    expected.update(profiles)
    expected.update(actions)
    expected.update(file_feedback)
    expected.update(download_lifecycle)
else:
    raise ValueError('Unknown UI test scope')

while pending:
    reference = pending.pop()
    if reference in seen:
        continue
    seen.add(reference)
    command = ['xcrun', 'xcresulttool', 'get', '--path', bundle, '--format', 'json']
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
            if payload and name in expected:
                subprocess.run(['xcrun', 'xcresulttool', 'export', '--type', 'file', '--path', bundle,
                                '--id', payload, '--output-path', str(destination / (name + '.png'))], check=True)
                exported.add(name)
            stack.extend(item.values())

if exported != expected:
    raise RuntimeError(f'Expected native UI regression screenshots; got {exported}')
print('PASS exported native swipe, README, local commit, folding and source scrolling screenshots')
