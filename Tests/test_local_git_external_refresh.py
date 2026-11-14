"""Filza return lifecycle and explicit missing-origin association contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExternalProjectTests(unittest.TestCase):
    def test_foreground_refresh_waits_for_editors_and_existing_operations(self):
        page = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text(encoding='utf-8')
        self.assertIn('@Environment(\\.scenePhase)', page)
        self.assertIn('.onChange(of: scenePhase)', page)
        self.assertIn('.onChange(of: busy)', page)
        self.assertIn('.onChange(of: sheet?.id)', page)
        body = page.split('private func refreshExternalChanges()', 1)[1].split('private func check(', 1)[0]
        for condition in ['externalRefreshPending', 'visible', 'scenePhase == .active', '!busy', 'sheet == nil', '!pendingCommit', 'syncing == nil', 'valid']:
            self.assertIn(condition, body)
        self.assertLess(body.index('externalRefreshPending = false'), body.index('await check(force: true)'))
        self.assertIn('state.filesChanged()', body)
        self.assertNotIn('sync(', body)

    def test_missing_remote_is_distinguished_and_configured_only_after_confirmation(self):
        page = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text(encoding='utf-8')
        picker = (ROOT / 'RepoPocket/LocalGitPickers.swift').read_text(encoding='utf-8')
        engine = (ROOT / 'RepoPocket/LocalGitEngine.swift').read_text(encoding='utf-8')
        bridge = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text(encoding='utf-8')
        self.assertIn('snapshot.history.remoteMissing == true', page)
        self.assertIn('LocalProjectRemoteView(', page)
        self.assertIn('.confirmationDialog(', picker)
        self.assertIn('"configureRemote"', picker)
        self.assertIn('"configureRemote"', engine)
        self.assertIn('@"remoteMissing"', bridge)
        body = bridge.split('static NSDictionary *RPConfigureRemote(', 1)[1].split('static NSDictionary *RPHistory(', 1)[0]
        for contract in ['RPAllowedRemote', 'git_config_lock', 'git_config_iterator_glob_new', 'remote\\\\.origin', 'RPExpected', 'RPIsCancelled', 'git_transaction_commit']:
            self.assertIn(contract, body)
        for unwanted in ['git_checkout', 'git_index_write', 'git_remote_push', 'RPFetch(']:
            self.assertNotIn(unwanted, body)


if __name__ == '__main__':
    unittest.main()
