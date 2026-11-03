"""Exercise history through the production bridge on real, offline repositories."""
from pathlib import Path
import ctypes
import json
import subprocess
import threading
import time
import unittest
import uuid
from test_local_git_native import NativeGitBehavior

ROOT = Path(__file__).resolve().parents[1]


class HistoryBehavior(NativeGitBehavior):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        models = (ROOT / 'RepoPocket/LocalGitModels.swift').read_text()
        history_models = models[models.index('struct LocalGitCommit:'):models.index('struct LocalGitDocument')]
        fixture = Path(cls.library_dir.name) / 'decode-history.swift'
        fixture.write_text('import Foundation\n' + history_models + '\n'
                           'let history = try JSONDecoder().decode(LocalGitHistory.self, '
                           'from: FileHandle.standardInput.readDataToEndOfFile())\n'
                           'precondition(history.totalCount != nil && history.head != nil && '
                           'history.reference != nil && history.offset != nil && history.shallow != nil)\n')
        cls.history_decoder = str(Path(cls.library_dir.name) / 'decode-history')
        subprocess.run(['xcrun', 'swiftc', str(fixture), '-o', cls.history_decoder], check=True)

    def call(self, operation, **values):
        response = super().call(operation, **values)
        if operation == 'history' and response.get('ok'):
            decoded = subprocess.run([self.history_decoder], input=json.dumps(response['result']).encode(),
                                     capture_output=True)
            self.assertEqual(decoded.returncode, 0, decoded.stderr.decode(errors='replace'))
        return response

    def make_history(self):
        for i in range(64):
            self.git('commit', '--allow-empty', '-m', f'history {i}')
        return self.git('rev-parse', 'HEAD')

    def test_history_count_and_bounded_pages(self):
        head = self.make_history()
        expected = self.git('rev-list', '--topo-order', 'HEAD').splitlines()
        pages = [self.result('history', expectedHead=head, offset=offset, limit=30)
                 for offset in (0, 30, 60)]
        self.assertEqual([p['totalCount'] for p in pages], [65, 65, 65])
        self.assertEqual([len(p['commits']) for p in pages], [30, 30, 5])
        self.assertEqual([c['sha'] for p in pages for c in p['commits']], expected)
        self.assertEqual(len({c['sha'] for p in pages for c in p['commits']}), 65)
        self.assertEqual([p['offset'] for p in pages], [0, 30, 60])
        self.assertEqual([p['head'] for p in pages], [head] * 3)
        self.assertEqual([p['reference'] for p in pages], ['refs/heads/main'] * 3)
        self.assertTrue(all(p['shallow'] is False for p in pages))
        self.assertEqual(self.result('history', offset=65)['commits'], [])
        self.assertEqual(self.result('history', offset=100)['commits'], [])
        self.assertEqual(len(self.result('history', limit=7)['commits']), 7)
        self.git('commit', '--allow-empty', '-m', 'new tip')
        self.assertFalse(self.call('history', expectedHead=head, offset=30)['ok'])
        self.assertEqual(self.result('history')['totalCount'], 66)
        self.git('checkout', '-b', 'short', self.head)
        self.assertFalse(self.call('history', expectedHead=head,
                                   expectedRef='refs/heads/short', offset=30)['ok'])
        short = self.result('history', expectedRef='refs/heads/short')
        # All 66 objects remain locally; only this branch's single ancestor counts.
        self.assertEqual(short['totalCount'], 1)
        self.assertEqual(short['reference'], 'refs/heads/short')
        self.git('branch', 'same-tip')
        self.git('checkout', 'same-tip')
        self.assertFalse(self.call('history', expectedHead=self.head,
                                   expectedRef='refs/heads/short', offset=1)['ok'])

    def test_history_shallow_and_invalid_bounds(self):
        for i in range(8):
            self.git('commit', '--allow-empty', '-m', f'shallow {i}')
        source = self.work
        shallow = source.parent / 'shallow'
        self.git('clone', '--depth=3', source.as_uri(), str(shallow))
        self.work = shallow
        history = self.result('history')
        self.assertEqual(history['totalCount'], 3)
        self.assertEqual(len(history['commits']), 3)
        self.assertIs(history['shallow'], True)
        self.assertEqual(self.git('rev-list', '--count', 'HEAD'), '3')
        self.assertEqual(self.git('rev-list', '--count', 'HEAD', cwd=source), '9')
        for values in ({'offset': -1}, {'limit': 31}, {'limit': 0}, {'offset': 0.5},
                       {'limit': 1.5}, {'offset': '30'}, {'limit': None}):
            with self.subTest(values=values):
                self.assertFalse(self.call('history', **values)['ok'])

    def paused_history(self, action):
        head = self.make_history()
        request_id = str(uuid.uuid4())
        marker = self.work / '.git/repopocket-test-history-paused'
        replies = []
        failures = []

        def read():
            try:
                replies.append(self.call('history', expectedHead=head, offset=30,
                                         requestID=request_id, testPauseHistory=True))
            except BaseException as error:
                failures.append(error)

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + 8
            while not marker.exists() and reader.is_alive() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(marker.exists(), 'History never reached its controlled walk boundary')
            action(request_id)
        finally:
            marker.unlink(missing_ok=True)
            reader.join(timeout=8)
        self.assertFalse(reader.is_alive(), 'Cancelled/invalidated history did not finish')
        if failures:
            raise failures[0]
        self.assertEqual(len(replies), 1)
        self.assertIs(replies[0]['ok'], False)
        self.assertNotIn('result', replies[0], 'Never publish a partial count/page')
        self.assertEqual((self.work / '代码.py').read_text(), 'print("old")\n')

    def test_history_cancelled_during_walk(self):
        self.native.rp_git_cancel.argtypes = [ctypes.c_char_p]
        self.paused_history(lambda request_id: self.native.rp_git_cancel(request_id.encode()))
        self.assertEqual(self.result('history')['totalCount'], 65)

    def test_history_head_changes_during_walk(self):
        self.paused_history(lambda _: self.git('commit', '--allow-empty', '-m', 'concurrent tip'))
        self.assertEqual(self.result('history')['totalCount'], 66)

    def test_history_branch_changes_during_walk(self):
        self.paused_history(lambda _: self.git('checkout', '-b', 'same-head'))
        self.assertEqual(self.result('history', expectedRef='refs/heads/same-head')['totalCount'], 65)


class HistoryContract(unittest.TestCase):
    def test_native_history_has_count_and_bounded_page_contract(self):
        bridge = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        body = bridge.split('static NSDictionary *RPHistory(', 1)[1].split('typedef struct', 1)[0]
        for token in ('@"totalCount"', '@"offset"', '@"expectedHead"', '@"expectedRef"',
                      'GIT_ITEROVER', 'RPIsCancelled', 'git_commit_free(commit)'):
            self.assertIn(token, body)
        self.assertNotIn('KEEP(commit,', body)

    def test_history_collapse_cancels_pending_pages(self):
        view = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text()
        section = view.split('private func historySection(', 1)[1].split('private func historyIdentity(', 1)[0]
        self.assertIn('.onChange(of: historyExpanded)', section)
        self.assertIn('if !expanded { resetHistoryPages() }', section)
        self.assertNotIn('{ _,', section, 'History onChange must support iOS 16')


def load_tests(loader, tests, pattern):
    suite = loader.loadTestsFromTestCase(HistoryContract)
    for name in HistoryBehavior.__dict__:
        if name.startswith('test_'):
            suite.addTest(HistoryBehavior(name))
    return suite


if __name__ == '__main__':
    unittest.main()
