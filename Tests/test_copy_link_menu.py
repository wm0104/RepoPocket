"""Guard the copy-link entry points added for the Coolapk feedback.

Cases: file link, file raw link, folder link, current-directory link, and the
rule that the root page copies the repository URL instead of a tree URL.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8')
RULES = (ROOT / 'RepoPocket/RepositoryLinkRules.swift').read_text(encoding='utf-8')

# File rows: blob link and raw link share one builder with different flags.
assert 'Label("复制文件链接"' in APP
assert 'Label("复制 raw 链接"' in APP
assert 'raw: true' in APP

# Folder rows: tree link only, no raw for directories.
assert 'Label("复制文件夹链接"' in APP
folder_call = APP.split('Label("复制文件夹链接"', 1)[0]
assert 'folder: true' in folder_call.rsplit('contentURL(', 1)[1]

# The directory menu copies the current folder, falling back to the repo URL at root.
assert 'Label("复制当前目录链接"' in APP
assert 'path.isEmpty ? RepositoryLinkRules.canonicalURL(repo)' in APP

# One shared builder: blob/tree and raw hosts live in the rules file only.
assert 'static func contentURL(' in RULES
assert 'blob' in RULES and 'tree' in RULES
assert 'raw.githubusercontent.com' in RULES
for stray in ('github.com/" + repo', 'raw.githubusercontent.com/" + repo'):
    assert stray not in APP, stray

print('PASS copy-link menu: file, raw, folder and current-directory entry points')
