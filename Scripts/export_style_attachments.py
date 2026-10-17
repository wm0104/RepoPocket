"""Export native UI regression screenshots from Xcode 15."""
import json
from pathlib import Path
import subprocess
import sys

bundle, output = sys.argv[1:]
destination = Path(output)
destination.mkdir(parents=True, exist_ok=True)
pending = [None]
seen = set()
exported = set()
expected = {'swipe-first', 'swipe-middle', 'swipe-last', 'readme-badges'}
expected.update({'workflow-step-output', 'local-folder-selection', 'long-patch-leading', 'local-import-picker', 'recorded-patch-leading'})
expected.update({'local-deb-editor', 'local-whole-folder-import'})
expected.update({'local-history-collapsed', 'local-history-expanded', 'local-commit-detail',
                 'local-commit-patch', 'local-history-after-folding'})
expected.update({'source-preview-left', 'source-preview-right', 'source-editor-left', 'source-editor-right'})
expected.update({'patch-highlight-left', 'patch-highlight-right', 'patch-raw-left', 'patch-raw-right'})

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
