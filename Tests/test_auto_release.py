from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch

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
        self.commit_response = {'sha': 'a' * 40, 'commit': {'message': '修复账号授权\n\n保留身份与权限保护。\n\n增加工作流摘要。\n'}}
        self.commit_error = None
        self.commit_raw = None
        self.uploaded_assets = None
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if args[0] == 'api':
            if '/releases?' in args[1]:
                return json.dumps([self.releases])
            if '/commits/' in args[1]:
                if self.commit_error:
                    raise self.commit_error
                return self.commit_raw if self.commit_raw is not None else json.dumps(self.commit_response)
            if '/git/matching-refs/' in args[1]:
                return json.dumps([] if self.tag_sha is None else [{'ref': 'refs/tags/v1.2.6', 'object': {'type': 'commit', 'sha': self.tag_sha}}])
        if args[:2] == ('release', 'view'):
            return json.dumps({'assets': self.uploaded_assets if self.uploaded_assets is not None else [{'name': p.name, 'size': p.stat().st_size,
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
        self.ipa_checksum = self.dist / 'RepoPocket.ipa.sha256'
        self.ipa_checksum.write_text(hashlib.sha256(self.packages[0].read_bytes()).hexdigest() + '  RepoPocket.ipa\n')
        (self.dist / 'build-info.json').write_text(json.dumps({'version': '1.2.6', 'sha': self.sha}))
        self.uploads = self.packages + [self.ipa_checksum, self.dist / 'SHA256SUMS', self.dist / 'build-info.json']

    def publish(self, gh):
        return self.release.publish(self.root, self.dist, self.sha, 'wm0104/RepoPocket', gh=gh)

    def test_publish_only_strictly_newer_numeric_stable_version(self):
        for version, tags, wanted in [('1.2.6', ['v1.2.5'], True), ('1.2.6', ['v1.2.6'], False),
                                      ('1.2.6', ['v1.3.0'], False), ('1.2.10', ['v1.2.9'], True)]:
            with self.subTest(version=version, tags=tags):
                releases = [{'tag_name': t, 'draft': False, 'prerelease': False} for t in tags]
                self.assertEqual(self.release.should_publish(version, releases), wanted)

    def test_same_or_older_version_skips_without_reading_commit_or_assets(self):
        self.notes.unlink()
        (self.dist / 'build-info.json').unlink()
        for tag in ['v1.2.6', 'v1.3.0']:
            with self.subTest(tag=tag):
                gh = FakeGitHub([], [{'tag_name': tag, 'draft': False, 'prerelease': False}])
                gh.commit_error = RuntimeError('must not read commit')
                self.assertFalse(self.publish(gh))
                self.assertEqual(gh.calls, [('api', 'repos/wm0104/RepoPocket/releases?per_page=100', '--paginate', '--slurp')])

    def test_invalid_commit_response_never_writes_new_or_existing_draft(self):
        invalid = [None, [], {}, {'sha': 'b' * 40, 'commit': {'message': '更新'}},
                   {'sha': self.sha}, {'sha': self.sha, 'commit': None},
                   {'sha': self.sha, 'commit': []}, {'sha': self.sha, 'commit': {} }]
        invalid += [{'sha': self.sha, 'commit': {'message': message}}
                    for message in [None, 123, [], {}, '', ' \n\t']]
        for drafts in [[], [{'tag_name': 'v1.2.6', 'draft': True, 'target_commitish': self.sha}]]:
            for response in invalid:
                with self.subTest(drafts=drafts, response=response):
                    gh = FakeGitHub(self.uploads, drafts)
                    gh.commit_response = response
                    with self.assertRaises(ValueError):
                        self.publish(gh)
                    self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_commit_api_error_never_writes_new_or_existing_draft(self):
        for drafts in [[], [{'tag_name': 'v1.2.6', 'draft': True, 'target_commitish': self.sha}]]:
            with self.subTest(drafts=drafts):
                gh = FakeGitHub(self.uploads, drafts)
                gh.commit_error = RuntimeError('commit API unavailable')
                with self.assertRaisesRegex(RuntimeError, 'commit API unavailable'):
                    self.publish(gh)
                self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_malformed_commit_json_never_writes_new_or_existing_draft(self):
        for drafts in [[], [{'tag_name': 'v1.2.6', 'draft': True, 'target_commitish': self.sha}]]:
            for raw in ['', '{invalid']:
                with self.subTest(drafts=drafts, raw=raw):
                    gh = FakeGitHub(self.uploads, drafts)
                    gh.commit_raw = raw
                    with self.assertRaises(ValueError):
                        self.publish(gh)
                    self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_github_passes_full_message_as_one_argv_without_shell(self):
        body = '--draft=false\n\n原文 "引号" $(echo unchanged)\n\n第二段'
        with patch.object(self.release.subprocess, 'run') as run:
            run.return_value.stdout = 'ok'
            self.assertEqual(self.release.github('release', 'create', 'v1.2.6', '--notes', body), 'ok')
        run.assert_called_once_with(['gh', 'release', 'create', 'v1.2.6', '--notes', body],
                                    check=True, capture_output=True, text=True)

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

    def test_missing_or_inconsistent_ipa_checksum_blocks_upload(self):
        for value in [None, '0' * 64 + '  RepoPocket.ipa\n', self.ipa_checksum.read_text().replace('.ipa', '.tipa')]:
            with self.subTest(value=value):
                if value is None:
                    self.ipa_checksum.unlink()
                else:
                    self.ipa_checksum.write_text(value)
                gh = FakeGitHub(self.uploads)
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
        self.assertEqual(create[create.index('--notes') + 1], gh.commit_response['commit']['message'].strip())
        self.assertIn(('api', f'repos/wm0104/RepoPocket/commits/{self.sha}'), gh.calls)
        self.assertFalse(any('--generate-notes' in c or '--notes-file' in c for c in gh.calls))
        edit = gh.calls[-1]
        self.assertEqual(edit[:3], ('release', 'edit', 'v1.2.6'))
        self.assertIn('--draft=false', edit)
        self.assertEqual(edit[edit.index('--notes') + 1], gh.commit_response['commit']['message'].strip())

    def test_full_message_preserved_without_markdown_for_new_and_resumed_draft(self):
        self.notes.unlink()
        message = ' \n修复 1.2.6 授权\n\n正文保留  两个空格。\n\n- --draft=false\n- $(echo unchanged) "引号"\n\nSigned-off-by: author\n\t'
        for drafts in [[], [{'tag_name': 'v1.2.6', 'draft': True, 'target_commitish': self.sha}]]:
            with self.subTest(drafts=drafts):
                gh = FakeGitHub(self.uploads, drafts)
                gh.commit_response['commit']['message'] = message
                self.assertTrue(self.publish(gh))
                writes = [c for c in gh.calls if c[:2] in [('release', 'create'), ('release', 'edit')]]
                self.assertEqual(len(writes), 1 if drafts else 2)
                for call in writes:
                    self.assertEqual(call[call.index('--notes') + 1], message.strip())
                self.assertFalse(any('--generate-notes' in c or '--notes-file' in c for c in gh.calls))

    def test_subject_only_commit_message_is_valid(self):
        gh = FakeGitHub(self.uploads)
        gh.commit_response['commit']['message'] = '修复授权'
        self.assertTrue(self.publish(gh))
        self.assertEqual(gh.calls[-1][-2:], ('--notes', '修复授权'))

    def test_other_source_or_duplicate_drafts_are_not_replaced(self):
        for drafts in [[{'tag_name': 'v1.2.6', 'draft': True, 'target_commitish': 'b' * 40}],
                       [{'tag_name': 'v1.2.6', 'draft': True, 'target_commitish': self.sha}] * 2]:
            with self.subTest(drafts=drafts):
                gh = FakeGitHub(self.uploads, drafts)
                with self.assertRaises(ValueError):
                    self.publish(gh)
                self.assertFalse(any(c[0] == 'release' for c in gh.calls))

    def test_uploaded_asset_verification_failure_keeps_draft_unpublished(self):
        for case in ['missing', 'size', 'digest']:
            with self.subTest(case=case):
                gh = FakeGitHub(self.uploads)
                gh.uploaded_assets = [{'name': p.name, 'size': p.stat().st_size,
                    'digest': 'sha256:' + hashlib.sha256(p.read_bytes()).hexdigest()} for p in self.uploads]
                if case == 'missing':
                    gh.uploaded_assets.pop()
                elif case == 'size':
                    gh.uploaded_assets[0]['size'] += 1
                else:
                    gh.uploaded_assets[0]['digest'] = 'sha256:' + '0' * 64
                with self.assertRaises(ValueError):
                    self.publish(gh)
                self.assertFalse(any(c[:2] == ('release', 'edit') for c in gh.calls))


if __name__ == '__main__':
    unittest.main()
