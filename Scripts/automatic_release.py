"""Publish a strictly newer stable version from the same verified CI artifact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def stable_version(value):
    match = re.fullmatch(r'v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))', value)
    if not match:
        raise ValueError('Release version must have three numeric components')
    return tuple(map(int, match[1].split('.')))


def project_version(root):
    source = (root / 'project.yml').read_text(encoding='utf-8')
    versions = []
    for key in ['MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
        matches = re.findall(rf'^\s*{key}:\s*"([^"]+)"\s*$', source, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f'Expected one {key}')
        stable_version(matches[0])
        versions.append(matches[0])
    if versions[0] != versions[1]:
        raise ValueError('Application and build versions differ')
    return versions[0]


def should_publish(version, releases):
    current = stable_version(version)
    published = []
    for release in releases:
        if release.get('draft') or release.get('prerelease'):
            continue
        try:
            published.append(stable_version(release['tag_name']))
        except ValueError:
            continue  # Historical non-SemVer tags are not stable release versions.
    return not published or current > max(published)


def github(*args):
    return subprocess.run(['gh', *args], check=True, capture_output=True, text=True).stdout


def verified_files(assets, version, sha):
    info = json.loads((assets / 'build-info.json').read_text(encoding='utf-8'))
    if info != {'version': version, 'sha': sha}:
        raise ValueError('Artifact version or source commit does not match this build')
    names = ['RepoPocket.ipa', 'RepoPocket.tipa', f'RepoPocket_{version}_iphoneos-arm64.deb', f'RepoPocket_{version}_iphoneos-arm64e.deb']
    checksums = {}
    for line in (assets / 'SHA256SUMS').read_text(encoding='utf-8').splitlines():
        match = re.fullmatch(r'([a-f0-9]{64}) [ *]([^/\\]+)', line)
        if not match or match[2] in checksums:
            raise ValueError('Invalid or duplicate artifact checksum')
        checksums[match[2]] = match[1]
    if set(checksums) != set(names):
        raise ValueError('The artifact must include all four expected packages')
    files = [assets / name for name in names]
    for path in files:
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0 or hashlib.sha256(path.read_bytes()).hexdigest() != checksums[path.name]:
            raise ValueError(f'Package verification failed: {path.name}')
    ipa_checksum = assets / 'RepoPocket.ipa.sha256'
    if (not ipa_checksum.is_file() or ipa_checksum.is_symlink()
            or ipa_checksum.read_text(encoding='ascii').splitlines() != [checksums['RepoPocket.ipa'] + '  RepoPocket.ipa']):
        raise ValueError('The IPA checksum file must match the verified package')
    return files + [ipa_checksum, assets / 'SHA256SUMS', assets / 'build-info.json']


def publish(root, assets, sha, repo, gh=github):
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('An exact source commit is required')
    version = project_version(root)
    releases = [r for page in json.loads(gh('api', f'repos/{repo}/releases?per_page=100', '--paginate', '--slurp')) for r in page]
    if not should_publish(version, releases):
        print('Version is unchanged or older; no release will be published.')
        return False
    files = verified_files(assets, version, sha)
    commit = json.loads(gh('api', f'repos/{repo}/commits/{sha}'))
    if not isinstance(commit, dict) or commit.get('sha') != sha or not isinstance(commit.get('commit'), dict):
        raise ValueError('Release notes require the exact build commit')
    body = commit['commit'].get('message')
    if not isinstance(body, str) or not body.strip():
        raise ValueError('Build commit message must be a nonempty string')
    body = body.strip()
    tag = 'v' + version
    refs = json.loads(gh('api', f'repos/{repo}/git/matching-refs/tags/{tag}'))
    for ref in refs:
        if ref['ref'] == 'refs/tags/' + tag:
            if ref['object'].get('type') != 'commit' or ref['object'].get('sha') != sha:
                raise ValueError('Existing tag targets another commit; it will not be moved')
    drafts = [r for r in releases if r['tag_name'] == tag and r.get('draft')]
    if drafts:
        if len(drafts) != 1 or drafts[0].get('target_commitish') != sha:
            raise ValueError('Existing draft belongs to another build; it will not be replaced')
    else:
        gh('release', 'create', tag, '--repo', repo, '--target', sha, '--draft',
           '--title', 'RepoPocket-' + version, '--notes', body)
    gh('release', 'upload', tag, '--repo', repo, '--clobber', *map(str, files))
    uploaded = json.loads(gh('release', 'view', tag, '--repo', repo, '--json', 'assets'))['assets']
    if {a['name'] for a in uploaded} != {p.name for p in files}:
        raise ValueError('Uploaded assets are incomplete or unexpected; draft is not published')
    for path in files:
        asset = next(a for a in uploaded if a['name'] == path.name)
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        if asset['size'] != path.stat().st_size or (asset.get('digest') and asset['digest'] != digest):
            raise ValueError('Uploaded asset verification failed; draft is not published')
    gh('release', 'edit', tag, '--repo', repo, '--draft=false', '--latest', '--notes', body)
    print(f'Published https://github.com/{repo}/releases/tag/{tag}')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['version', 'manifest', 'publish'])
    parser.add_argument('--assets', type=Path, default=Path('dist'))
    parser.add_argument('--sha', default=os.environ.get('GITHUB_SHA', ''))
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', 'wm0104/RepoPocket'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.mode == 'version':
        print(project_version(root))
    elif args.mode == 'manifest':
        if not re.fullmatch(r'[a-f0-9]{40}', args.sha):
            raise ValueError('Build manifest requires an exact source commit')
        (args.assets / 'build-info.json').write_text(json.dumps({'version': project_version(root), 'sha': args.sha}) + '\n', encoding='utf-8')
    else:
        publish(root, args.assets, args.sha, args.repo)


if __name__ == '__main__':
    main()
