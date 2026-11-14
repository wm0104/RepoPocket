"""Remote history rewrite plans and atomic current-branch publication guards."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid
from repository_operations_support import run_operations_fixture

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    path = ROOT / 'RepoPocket' / name
    return path.read_text(encoding='utf-8') if path.exists() else ''


class RemoteHistoryStructureTests(unittest.TestCase):
    def test_explicit_ref_rejection_is_terminal_but_unknown_is_not_unlocked(self):
        api = source('GitHub.swift').split('    func historyUpdateRef(', 1)[1]
        self.assertIn('RemoteHistoryRefRejection', api)
        self.assertIn('payload?["updateRefs"] is NSNull', api)
        self.assertIn('$0.path == ["updateRefs"]', api)
        state = source('RemoteHistoryState.swift')
        self.assertIn('catch let rejection as RemoteHistoryRefRejection', state)
        self.assertIn('phase: "rejected"', state)
        self.assertIn('saved.record.phase == "update-requested"', state)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production backup records require native Swift')
    def test_backup_records_preserve_mappings_restart_and_account_cleanup(self):
        storage = source('RemoteHistoryBackup.swift').replace('import ZIPFoundation\n', '')
        start = storage.index('    @MainActor static func prepare(')
        end = storage.index('    static func update(', start)
        storage = storage[:start] + storage[end:]
        start = storage.index('    @MainActor static func archive(')
        end = storage.index('    static func removeAccount(', start)
        storage = storage[:start] + storage[end:]
        root = storage.split('    private static var root: URL {', 1)[1].split('\n    }', 1)[0]
        storage = storage.replace(root, '\n        fixtureRoot', 1)
        sha = source('RemoteBranchMerge.swift').split('    static func sha(', 1)[1].split('\n    }', 1)[0]
        support = 'import Foundation\nstruct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }\nenum RemoteBranchMergeRules { static func sha(' + sha + '\n} }\n'
        fixture = r'''
let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
extension RemoteHistoryBackup {
    static func verifyStorage() throws {
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let sha = String(repeating: "a", count: 40)
        let snapshot = RemoteHistorySnapshot(accountID: "private-A", generation: UUID(), repository: "owner/repo", repositoryID: "R_fixture", branch: "main", head: sha, commits: [])
        let preview = RemoteHistoryPreview(snapshot: snapshot, action: .versions, selected: [sha], steps: [], resultKey: "v1", versions: [], baseline: nil)
        let folder = accountRoot(snapshot.accountID).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try save(Record(createdAt: Date(), snapshot: snapshot, action: .versions, selected: [sha], steps: [], versions: [], baseline: nil, resultKey: "v1"), folder: folder)
        precondition(latest(accountID: "private-B", repo: "owner/repo", branch: "main") == nil)
        precondition(latest(accountID: "private-A", repo: "owner/repo", branch: "other") == nil)
        try update(folder, preview: preview, resolved: ["v1": sha], newHead: sha, phase: "objects-verified")
        try update(folder, preview: preview, resolved: ["v1": sha], newHead: sha, phase: "update-requested")
        let loaded = latest(accountID: "private-A", repo: "owner/repo", branch: "main")!
        precondition(loaded.record.resolved == ["v1": sha] && loaded.record.phase == "update-requested")
        let newGeneration = UUID()
        precondition(loaded.record.preview(generation: newGeneration).snapshot.generation == newGeneration)
        try update(folder, preview: preview, resolved: [:], newHead: sha, phase: "verified")
        let verified = try record(folder, accountID: "private-A")
        precondition(verified.resolved == ["v1": sha])
        try update(folder, preview: preview, resolved: [:], newHead: sha, phase: "rejected")
        let rejected = try record(folder, accountID: "private-A")
        precondition(rejected.phase == "rejected" && rejected.resolved == ["v1": sha])
        do { try validate(folder, accountID: "private-B"); preconditionFailure("cross-account backup accepted") } catch {}
        let b = accountRoot("private-B")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let marker = b.appendingPathComponent("marker"); try Data("keep".utf8).write(to: marker)
        removeAccount("private-A")
        precondition(!FileManager.default.fileExists(atPath: folder.path) && FileManager.default.fileExists(atPath: marker.path))
        print("PASS private backup record restart/mapping/account separation and removal")
    }
}
@main struct Run { static func main() throws { try RemoteHistoryBackup.verifyStorage() } }
'''
        with tempfile.TemporaryDirectory(prefix='repopocket-backup-records-') as directory:
            folder = Path(directory); swift = folder / 'Fixture.swift'; binary = folder / 'fixture'
            swift.write_text(support + source('RemoteHistoryModels.swift') + storage + fixture, encoding='utf-8')
            subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)

    def test_version_mode_uses_confirmed_snapshot_titles_and_notes(self):
        models = source('RemoteHistoryModels.swift')
        for token in ['RemoteHistoryVersion', 'versionPreview', 'baseline', 'finalCommit', 'versions.last', '版本号', '更新要点']:
            self.assertTrue(token in models, token)
        ui = source('RemoteHistoryView.swift')
        for token in ['按版本整理', '保留基线', '最终快照', '最终保留', 'versionPreview']:
            self.assertTrue(token in ui, token)
        self.assertNotIn('.monospaced()', ui, 'Keep the iOS 15 deployment floor; use Font.system design instead of the iOS 16.4 View modifier')

    def test_original_history_is_backed_up_and_each_new_tree_verified_before_publish(self):
        state = source('RemoteHistoryState.swift')
        self.assertIn('RemoteHistoryBackup.prepare', state)
        self.assertIn('tree == step.tree', state)
        self.assertLess(state.index('RemoteHistoryBackup.prepare'), state.index('api.historyCreateCommit'))
        self.assertLess(state.index('tree == step.tree'), state.index('api.historyUpdateRef'))
        backup = source('RemoteHistoryBackup.swift')
        for token in ['accountID', 'historyBackup', 'objects-verified', 'update-requested', 'resolved', '.atomic']:
            self.assertTrue(token in backup, token)
    @unittest.skipUnless(shutil.which('swiftc'), 'Production history transport/state requires native Swift')
    def test_production_atomic_transport_races_and_lost_responses(self):
        run_operations_fixture('history')

    def test_graph_and_selection_are_validated_before_creating_objects(self):
        text = source('RemoteHistoryModels.swift')
        for token in ['topologicalOrder', 'selected.isSubset', 'snapshot.head', 'snapshot.tree',
                      'maximumCommits', 'parents', 'case clear, squash', '当前代码快照']:
            self.assertTrue(token in text, token)

    def test_publication_uses_atomic_expected_head_not_rest_force_patch(self):
        text = source('GitHub.swift')
        for token in ['updateRefs(input:', '"beforeOid": preview.snapshot.head',
                      '"afterOid": newHead', '"name": "refs/heads/" + preview.snapshot.branch']:
            self.assertTrue(token in text, token)

    def test_unknown_write_is_reconciled_read_only(self):
        text = source('RemoteHistoryState.swift')
        for token in ['pendingHead', 'workspaceHead', 'historyCommitTree', 'await reconcile',
                      'AccountStore.generation', 'api.isCurrentSession', 'repositoryHistoryChanged',
                      'historyRepositoryID', '== preview.snapshot.repositoryID']:
            self.assertTrue(token in text, token)
        self.assertNotIn('retryWrite', text)

    def test_selection_is_separate_from_the_existing_local_history_guards(self):
        text = source('RemoteHistoryView.swift')
        for token in ['全选当前分支', '全部文件保持不变', 'NativeActionMenu',
                      'SoftGroupRows', '.confirmationDialog', '压缩成一条', '清除选中记录']:
            self.assertTrue(token in text, token)
        self.assertIn('RPHistoryPublished', (ROOT / 'Vendor/NativeGit/NativeGitHistory.inc').read_text(encoding='utf-8'))


@unittest.skipUnless(shutil.which('swiftc'), 'Production history plan and real temporary Git trees require Swift')
class RemoteHistoryPlanBehavior(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='repopocket-history-plan-')
        cls.addClassCleanup(cls.build.cleanup)
        folder = Path(cls.build.name)
        model = source('RemoteHistoryModels.swift')
        sha = source('RemoteBranchMerge.swift').split('    static func sha(', 1)[1].split('\n    }', 1)[0]
        support = 'import Foundation\nstruct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }\nenum RemoteBranchMergeRules { static func sha(' + sha + '\n} }\n'
        (folder / 'Support.swift').write_text(support, encoding='utf-8')
        (folder / 'Models.swift').write_text(model, encoding='utf-8')
        cls.executable = folder / 'plan'
        subprocess.run(['swiftc', '-parse-as-library', str(folder / 'Support.swift'), str(folder / 'Models.swift'),
                        str(ROOT / 'Tests/Fixtures/RemoteHistoryPlanHarness.swift'), '-o', str(cls.executable)], check=True)

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='repopocket-history-git-')
        self.addCleanup(self.folder.cleanup)
        self.repo = Path(self.folder.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.ids = []
        for index in range(4):
            (self.repo / '代码.txt').write_text(f'version {index}\n', encoding='utf-8')
            (self.repo / f'file-{index}.txt').write_text(str(index), encoding='utf-8')
            self.git('add', '.')
            self.git('commit', '-m', f'keep-{index}')
            self.ids.append(self.git('rev-parse', 'HEAD'))
        self.head = self.ids[-1]
        self.tree = self.git('rev-parse', 'HEAD^{tree}')

    def git(self, *args, input=None, env=None, check=True):
        result = subprocess.run(['git', '-C', str(self.repo), *args], input=input, env=env,
                                capture_output=True, text=True, encoding='utf-8', check=check)
        return result.stdout.strip() if check else result

    def payload(self, selected, action='clear'):
        commits = []
        for sha in self.git('rev-list', self.head).splitlines():
            name, email, date = self.git('show', '-s', '--format=%an|%ae|%aI', sha).split('|')
            author = {'name': name, 'email': email, 'date': date}
            commits.append({'sha': sha, 'commit': {'message': self.git('show', '-s', '--format=%B', sha),
                'tree': {'sha': self.git('rev-parse', sha + '^{tree}')}, 'author': author, 'committer': author},
                'parents': [{'sha': x} for x in self.git('show', '-s', '--format=%P', sha).split()]})
        return {'head': self.head, 'commits': commits, 'selected': selected, 'action': action, 'message': '当前代码快照'}

    def plan(self, payload, check=True):
        result = subprocess.run([str(self.executable)], input=json.dumps(payload, ensure_ascii=False),
                                capture_output=True, text=True, encoding='utf-8')
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def apply_objects(self, plan):
        mapped = {}
        for step in plan['steps']:
            if not step['recreate']:
                mapped[step['key']] = step['key']
                continue
            args = ['commit-tree', step['tree']]
            for parent in step['parents']:
                args += ['-p', mapped.get(parent, parent)]
            env = os.environ.copy()
            for field, prefix in [('author', 'GIT_AUTHOR_'), ('committer', 'GIT_COMMITTER_')]:
                author = step.get(field)
                if author:
                    env[prefix + 'NAME'] = author['name']; env[prefix + 'EMAIL'] = author['email']; env[prefix + 'DATE'] = author['date']
            mapped[step['key']] = self.git(*args, input=step['message'] + '\n', env=env)
        result = mapped[plan['resultKey']]
        self.assertEqual(self.git('rev-parse', result + '^{tree}'), self.tree)
        self.assertEqual(self.git('rev-parse', 'refs/heads/main'), self.head)
        return result

    def version_payload(self, baseline, versions):
        payload = self.payload([], action='versions')
        payload['baseline'] = baseline
        payload['versions'] = [{'id': str(uuid.uuid4()), 'version': version, 'finalCommit': sha, 'notes': notes}
                               for version, sha, notes in versions]
        return payload

    def test_versions_keep_each_final_tree_without_resurrecting_cancelled_experiments(self):
        base = self.ids[0]
        self.git('reset', '--hard', base)
        for index in range(2):
            (self.repo / '保留功能.txt').write_text(f'最终功能 {index}', encoding='utf-8')
            (self.repo / '不要的实验.txt').write_text('experiment', encoding='utf-8')
            self.git('add', '.'); self.git('commit', '-m', f'实验过程-{index}')
            self.git('rm', '不要的实验.txt')
            self.git('commit', '-m', f'撤掉实验并保留最终修复-{index}')
            if index == 0:
                first = self.git('rev-parse', 'HEAD')
        self.head = self.git('rev-parse', 'HEAD'); self.tree = self.git('rev-parse', 'HEAD^{tree}')
        self.git('branch', 'other'); self.git('tag', 'untouched')
        notes = ['- 完善最终保留功能\n- 修复实际问题', '- 完善第二版功能']
        plan = self.plan(self.version_payload(base, [('2.0.0', first, notes[0]), ('2.0.0-1', self.head, notes[1])]))
        self.assertEqual(len(plan['steps']), 2)
        result = self.apply_objects(plan)
        versions = self.git('rev-list', '--reverse', base + '..' + result).splitlines()
        self.assertEqual(len(versions), 2)
        for new, original, title, body in zip(versions, [first, self.head], ['2.0.0', '2.0.0-1'], notes):
            self.assertEqual(self.git('rev-parse', new + '^{tree}'), self.git('rev-parse', original + '^{tree}'))
            self.assertEqual(self.git('show', '-s', '--format=%B', new), title + '\n\n' + body)
            self.assertNotIn('不要的实验.txt', self.git('ls-tree', '-r', '--name-only', new))
        self.assertEqual(self.git('rev-parse', versions[0] + '^'), base)
        for ref in ['other', 'untouched', 'main']:
            self.assertEqual(self.git('rev-parse', ref), self.head)

    def test_versions_reject_guessed_or_incomplete_boundaries_and_notes(self):
        valid = [('3.0', self.ids[2], '- 第一版最终效果'), ('3.1', self.head, '- 第二版最终效果')]
        cases = [
            self.version_payload(self.ids[0], valid[:-1]),
            self.version_payload(self.ids[2], valid),
            self.version_payload(self.ids[0], [('3.0', self.head, '- 最后'), ('3.1', self.ids[2], '- 倒序'), ('3.2', self.head, '- 最后')]),
            self.version_payload(self.ids[0], [('3.0', self.ids[2], '- 第一版'), ('3.0', self.head, '- 重复版本')]),
            self.version_payload(self.ids[0], [('版本号修改为3.0', self.head, '- 说明')]),
            self.version_payload(self.ids[0], [('3.0\n过程', self.head, '- 说明')]),
            self.version_payload(self.ids[0], [('3.0', self.head, '')]),
            self.version_payload('f' * 40, valid),
            self.version_payload(self.ids[0], [('3.0', 'f' * 40, '- 未知'), ('3.1', self.head, '- 最后')]),
        ]
        for payload in cases:
            with self.subTest(payload=payload['versions']):
                self.plan(payload, check=False)

    def test_version_merge_snapshot_keeps_earlier_history_and_exact_merged_files(self):
        base = self.ids[0]
        self.git('checkout', '-b', 'side', base)
        (self.repo / 'side.txt').write_text('keep merged feature', encoding='utf-8')
        self.git('add', '.'); self.git('commit', '-m', 'side feature')
        self.git('checkout', 'main'); self.git('merge', '--no-ff', 'side', '-m', 'merge fixture')
        self.head = self.git('rev-parse', 'HEAD'); self.tree = self.git('rev-parse', 'HEAD^{tree}')
        plan = self.plan(self.version_payload(base, [('4.0', self.head, '- 保留合并后的最终功能')]))
        result = self.apply_objects(plan)
        self.assertEqual(self.git('rev-parse', result + '^'), base)
        self.assertEqual(self.git('show', result + ':side.txt'), 'keep merged feature')

    def test_version_from_root_is_an_explicit_one_snapshot_operation(self):
        result = self.apply_objects(self.plan(self.version_payload(None, [('5.0', self.head, '- 用户确认的完整快照')])))
        self.assertEqual(self.git('rev-list', '--count', result), '1')

    def test_partial_clear_preserves_final_tree_and_unselected_messages(self):
        selected = [self.ids[1]]
        new = self.apply_objects(self.plan(self.payload(selected)))
        self.assertNotIn(self.ids[1], self.git('rev-list', new).splitlines())
        self.assertEqual(set(self.git('log', '--format=%s', new).splitlines()), {'keep-0', 'keep-2', 'keep-3'})

    def test_full_clear_is_one_root_snapshot_and_keeps_other_refs(self):
        self.git('branch', 'other', self.ids[1]); self.git('tag', 'retained', self.head)
        plan = self.plan(self.payload(self.ids))
        new = self.apply_objects(plan)
        self.assertEqual(self.git('rev-list', '--count', new), '1')
        self.assertEqual(self.git('rev-parse', 'other'), self.ids[1])
        self.assertEqual(self.git('rev-parse', 'retained'), self.head)

    def test_selected_head_gets_a_snapshot_without_changing_kept_ancestor(self):
        new = self.apply_objects(self.plan(self.payload([self.head])))
        self.assertEqual(self.git('rev-parse', new + '^'), self.ids[-2])
        self.assertEqual(self.git('log', '-1', '--format=%s', new), '当前代码快照')

    def test_latest_contiguous_squash_preserves_older_history(self):
        new = self.apply_objects(self.plan(self.payload(self.ids[-2:], 'squash')))
        self.assertEqual(self.git('rev-parse', new + '^'), self.ids[1])
        self.assertEqual(self.git('rev-list', '--count', new), '3')

    def test_invalid_noncontiguous_empty_and_incomplete_graphs_are_rejected(self):
        for selection, action in [([], 'clear'), ([self.ids[0], self.head], 'squash'), (['f' * 40], 'clear')]:
            self.plan(self.payload(selection, action), check=False)
        missing = self.payload([self.head]); missing['commits'].pop()
        self.plan(missing, check=False)


if __name__ == '__main__':
    unittest.main()
