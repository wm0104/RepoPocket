from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def release_module():
    spec = importlib.util.spec_from_file_location('automatic_release', ROOT / 'Scripts/automatic_release.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeGitHub:
    def __init__(self, assets, releases=None, tag_sha=None, fail_upload=False):
        self.assets = assets
        self.releases = releases or []
        self.tag_sha = tag_sha
        self.fail_upload = fail_upload
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if args[0] == 'api':
            if '/releases?' in args[1]:
                return json.dumps([self.releases])
            if '/git/matching-refs/' in args[1]:
                return json.dumps([] if self.tag_sha is None else [{'ref': 'refs/tags/v1.2.6', 'object': {'type': 'commit', 'sha': self.tag_sha}}])
        if args[:2] == ('release', 'view'):
            return json.dumps({'assets': [{'name': p.name, 'size': p.stat().st_size,
                'digest': 'sha256:' + hashlib.sha256(p.read_bytes()).hexdigest()} for p in self.assets]})
        if args[:2] == ('release', 'upload') and self.fail_upload:
            raise RuntimeError('upload interrupted')
        return ''


class AutoReleaseTests(unittest.TestCase):
    def test_workflow_publishes_only_the_full_successful_canonical_build(self):
        workflow = (ROOT / '.github/workflows/build.yml').read_text(encoding='utf-8')
        build, publish = workflow.split('\n  publish:', 1)
        self.assertNotIn('contents: write', build)
        for gate in ["needs: build", "needs.build.result == 'success'", '!inputs.validate_only', '!inputs.fork_people_only',
                     '!inputs.build_update_probe', "github.repository == 'wm0104/RepoPocket'", 'refs/heads/test', 'refs/heads/main']:
            self.assertIn(gate, publish)
        self.assertIn('contents: write', publish)
        self.assertIn('cancel-in-progress: false', publish)
        self.assertIn('ref: ${{ github.sha }}', publish)
        self.assertIn('actions/download-artifact@v4', publish)
        self.assertIn('name: RepoPocket', publish)
        self.assertNotIn('xcodebuild', publish)
        self.assertIn('automatic_release.py manifest', build)
        self.assertIn('dist/build-info.json', build)

    def setUp(self):
        self.release = release_module()
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        (self.root / 'project.yml').write_text('MARKETING_VERSION: "1.2.6"\nCURRENT_PROJECT_VERSION: "1.2.6"\n')
        self.notes = self.root / 'docs/releases/1.2.6.md'
        self.notes.parent.mkdir(parents=True)
        self.notes.write_text('## 修复\n- 修复勾选社交账号管理后的登录错误。\n\n## 工作流\n- 增加摘要与原始页面入口。\n', encoding='utf-8')
        self.dist = self.root / 'dist'
        self.dist.mkdir()
        self.sha = 'a' * 40
        self.packages = []
        for name in ['RepoPocket.ipa', 'RepoPocket.tipa', 'RepoPocket_1.2.6_iphoneos-arm64.deb', 'RepoPocket_1.2.6_iphoneos-arm64e.deb']:
            path = self.dist / name
            path.write_bytes(('verified fixture ' + name).encode())
            self.packages.append(path)
        (self.dist / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in self.packages))
        (self.dist / 'build-info.json').write_text(json.dumps({'version': '1.2.6', 'sha': self.sha}))
        self.uploads = self.packages + [self.dist / 'SHA256SUMS', self.dist / 'build-info.json']

    def publish(self, gh):
        return self.release.publish(self.root, self.dist, self.sha, 'wm0104/RepoPocket', gh=gh)

    def test_publish_only_strictly_newer_numeric_stable_version(self):
        for version, tags, wanted in [('1.2.6', ['v1.2.5'], True), ('1.2.6', ['v1.2.6'], False),
                                      ('1.2.6', ['v1.3.0'], False), ('1.2.10', ['v1.2.9'], True)]:
            with self.subTest(version=version, tags=tags):
                releases = [{'tag_name': t, 'draft': False, 'prerelease': False} for t in tags]
                self.assertEqual(self.release.should_publish(version, releases), wanted)

    def test_same_version_skips_without_touching_notes_or_assets(self):
        self.notes.unlink()
        gh = FakeGitHub([], [{'tag_name': 'v1.2.6', 'draft': False, 'prerelease': False}])
        self.assertFalse(self.publish(gh))
        self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_new_version_requires_real_notes_without_a_version_heading(self):
        for text in ['', '# 1.2.6\n修复登录']:
            self.notes.write_text(text, encoding='utf-8')
            gh = FakeGitHub(self.uploads)
            with self.assertRaises(ValueError):
                self.publish(gh)
            self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_bad_packages_or_wrong_build_commit_never_publish(self):
        for case in ['hash', 'manifest']:
            with self.subTest(case=case):
                if case == 'hash':
                    self.packages[0].write_bytes(b'corrupted')
                else:
                    self.packages[0].write_bytes(('verified fixture ' + self.packages[0].name).encode())
                    (self.dist / 'build-info.json').write_text(json.dumps({'version': '1.2.6', 'sha': 'b' * 40}))
                gh = FakeGitHub(self.uploads)
                with self.assertRaises(ValueError):
                    self.publish(gh)
                self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_a_tag_on_a_different_commit_is_not_moved(self):
        gh = FakeGitHub(self.uploads, tag_sha='b' * 40)
        with self.assertRaises(ValueError):
            self.publish(gh)
        self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_upload_failure_keeps_the_release_unpublished(self):
        gh = FakeGitHub(self.uploads, fail_upload=True)
        with self.assertRaises(RuntimeError):
            self.publish(gh)
        self.assertFalse(any(c[:2] == ('release', 'edit') for c in gh.calls))

    def test_success_publishes_the_same_verified_build_and_authored_notes(self):
        gh = FakeGitHub(self.uploads, [{'tag_name': 'v1.2.5', 'draft': False, 'prerelease': False}])
        self.assertTrue(self.publish(gh))
        create = next(c for c in gh.calls if c[:2] == ('release', 'create'))
        self.assertIn('--draft', create)
        self.assertEqual(create[create.index('--target') + 1], self.sha)
        self.assertEqual(create[create.index('--notes-file') + 1], str(self.notes))
        self.assertFalse(any('--generate-notes' in c for c in gh.calls))
        edit = gh.calls[-1]
        self.assertEqual(edit[:3], ('release', 'edit', 'v1.2.6'))
        self.assertIn('--draft=false', edit)


if __name__ == '__main__':
    unittest.main()
