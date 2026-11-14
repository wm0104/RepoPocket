"""Production conflict bridge: all writes use disposable synthetic repositories only."""
from pathlib import Path
import json
import platform
import shutil
import tempfile
import subprocess
import sys
import time
import unittest
import test_local_git_native as fixtures
import test_local_git_merge as merges

ROOT = Path(__file__).resolve().parents[1]


class ConflictContracts(unittest.TestCase):
    def test_diagnostic_copy_preserves_shipping_guards(self):
        from conflict_diagnostics_support import instrument_conflict_bridge
        source = ROOT / 'Vendor/NativeGit'
        before = {p.name: p.read_bytes() for p in source.iterdir() if p.is_file()}
        with tempfile.TemporaryDirectory(prefix='repopocket-diagnostic-contract-') as directory:
            instrument_conflict_bridge(source, directory)
            self.assertEqual((Path(directory) / 'NativeGitBridge.m').read_bytes(), before['NativeGitBridge.m'])
            observed = (Path(directory) / 'NativeGitConflict.inc').read_text()
            original = before['NativeGitConflict.inc'].decode()
            for guard in [line for line in original.splitlines() if 'RPRequire(' in line]:
                self.assertIn(guard, observed)
            self.assertEqual(observed.count('git_blob_filter(&filtered,blob,entry->path,&options)'), 1)
            self.assertIn('RPCheck(diagnosticRC,', observed)
            for field in ('filter-output', 'rawHex', 'outputHex', 'equal', 'optionsSize', 'runtime',
                          'post-filter-review', 'containsCRLF', 'attrRC', 'attributes', 'post-filter-ctype'):
                self.assertIn(field, observed)
            self.assertIn('setlocale(LC_CTYPE,NULL)', observed)
            self.assertNotIn('setlocale(LC_CTYPE,"', observed)
            body = observed.split('static void RPConflictFilters(', 1)[1].split('static NSDictionary *RPConflictStart(', 1)[0]
            tail = '            }\n            RPFilterDiagnosticReview(repo,blob,entry->path,commitID,q);\n        } @finally { git_blob_free(blob); }'
            self.assertIn(tail, body)
            self.assertLess(body.index('git_blob_filter('), body.index('RPFilterDiagnosticReview('))
            self.assertNotIn('git_attr_get_many_ext(', body)
            self.assertNotIn('git_filter_list_load_ext(', body)
            self.assertEqual({p.name: p.read_bytes() for p in source.iterdir() if p.is_file()}, before)

    def test_direct_ci_script_runs_the_unittest_suite(self):
        import ast
        module = ast.parse(Path(__file__).read_text())
        for node in module.body:
            if isinstance(node, ast.If) and ast.unparse(node.test) == "__name__ == '__main__'":
                self.assertIn('unittest.main()', ast.unparse(node))
                return
        self.fail('Direct CI invocation must execute the conflict suite, not just define it')

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift fixture requires existing Swift compiler')
    def test_production_swift_blocks_and_decoding(self):
        with tempfile.TemporaryDirectory(prefix='repopocket-conflict-swift-') as directory:
            binary = str(Path(directory) / 'conflict-fixture')
            subprocess.run(['swiftc', str(ROOT / 'RepoPocket/LocalGitConflictModels.swift'),
                            str(ROOT / 'Tests/Fixtures/LocalGitConflictBlocksFixture.swift'), '-o', binary], check=True)
            subprocess.run([binary], check=True)

    def test_shipping_dispatch_and_write_coordination(self):
        bridge = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        engine = (ROOT / 'RepoPocket/LocalGitEngine.swift').read_text()
        self.assertIn('#include "NativeGitConflict.inc"', bridge)
        for operation in ('mergeStart', 'conflictStatus', 'conflictFile', 'conflictResolve', 'conflictContinue', 'conflictAbort'):
            self.assertIn('@"' + operation + '"', bridge)
        for operation in ('mergeStart', 'conflictResolve', 'conflictContinue', 'conflictAbort'):
            self.assertIn('"' + operation + '"', engine.split('coordinate(root, writing:', 1)[1])
        self.assertIn('return RPConflictPull(repo,q,c)', bridge)
        self.assertIn('@"mergePending"', bridge)

    def test_no_shell_reset_force_or_untracked_clean(self):
        native = (ROOT / 'Vendor/NativeGit/NativeGitConflict.inc').read_text()
        for forbidden in ('system(', 'popen(', 'NSTask', 'GIT_CHECKOUT_FORCE', 'git_reset(', 'GIT_CHECKOUT_REMOVE_UNTRACKED', 'git_repository_state_cleanup'):
            self.assertNotIn(forbidden, native)
        self.assertIn('options.flags &= ~GIT_BLOB_FILTER_CHECK_FOR_BINARY', native)
        for required in ('RPConflictIndexFingerprint', 'RPConflictWorktree', 'RPClearStaleOwnedLocks',
                         'RPConflictLockIndex', 'git_index_conflict_remove', 'git_index_has_conflicts',
                         'MERGE_HEAD', 'MERGE_MSG', 'backupFingerprint', 'recoveryRef', 'RPMergeTreeBudget', 'RPIsCancelled'):
            self.assertIn(required, native)

    def test_post_lock_head_revalidation_and_session_bound_oid_lock_recovery(self):
        native = (ROOT / 'Vendor/NativeGit/NativeGitConflict.inc').read_text()
        body = native.split('static NSDictionary *RPConflictMutate(', 1)[1]
        locked = body.index('git_reference *lockedHead=RPHead(repo,c)')
        self.assertLess(body.index('RPLockHead(repo,head,c)'), locked)
        self.assertLess(locked, body.index('head=lockedHead'))
        self.assertLess(body.index('head=lockedHead'), body.index('RPConflictInstall(repo,record'))
        self.assertIn('git_reference_name(lockedHead)', body)
        bridge = (ROOT / 'Vendor/NativeGit/NativeGitBridge.m').read_text()
        recovery = bridge.split('static void RPClearStaleOwnedLocks(', 1)[1].split('static void RPTestCrash(', 1)[0]
        for guard in ('session[@"session"]', 'session[@"phase"]', 'session[@"reference"]',
                      'session[@"oldHead"]', 'session[@"newHead"]', 'lease[@"head"]',
                      'lock[@"inode"]', 'lock[@"birth"]', 'BOOL conflictTarget='):
            self.assertIn(guard, recovery)
        self.assertIn('conflictBeforePublishRename', body)

    def test_ui_uses_existing_editor_and_real_native_menus(self):
        editor = (ROOT / 'RepoPocket/LocalGitConflictEditor.swift').read_text()
        self.assertIn('SourceCodeEditor(', editor)
        self.assertIn('NativeActionMenu(', editor)
        self.assertIn('LocalGitConflictBlocks.applying', editor)
        self.assertNotIn('TextEditor(', editor)
        root = (ROOT / 'RepoPocket/LocalProjectView.swift').read_text()
        self.assertIn('snapshot.status.mergePending == true', root)
        self.assertIn('LocalGitConflictView(', root)
        self.assertIn('session.phase != "resolving"', (ROOT / 'RepoPocket/LocalGitConflictView.swift').read_text())


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS Foundation + production libgit2 required; not simulated')
class ConflictNative(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from conflict_diagnostics_support import instrument_conflict_bridge
        directory = tempfile.TemporaryDirectory(prefix='repopocket-filter-diagnostic-')
        cls.addClassCleanup(directory.cleanup)
        cls.native_bridge_source = instrument_conflict_bridge(ROOT / 'Vendor/NativeGit', Path(directory.name))
        fixtures.NativeGitBehavior.setUpClass.__func__(cls)

    def call(self, operation, **extra):
        if self._testMethodName.startswith('test_binary_checkout_transform_'):
            extra['filterDiagnostics'] = True
            print('BINARY_FILTER_OPERATION ' + operation, flush=True)
        return fixtures.NativeGitBehavior.call(self, operation, **extra)

    setUp = fixtures.NativeGitBehavior.setUp
    git = fixtures.NativeGitBehavior.git
    result = fixtures.NativeGitBehavior.result
    feature = merges.LocalMergeNative.feature
    make_remote = fixtures.NativeGitBehavior.make_remote

    def session(self):
        return self.result('conflictStatus')

    def args(self, session=None):
        s = session or self.session()
        return dict(session=s['session'], expectedHead=s['head'], expectedRef=s['reference'], indexFingerprint=s['indexFingerprint'])

    def start(self):
        args = self.feature(conflict=True, diverge=True)
        before = (self.work / '代码.py').read_bytes()
        result = self.result('mergeStart', **args)
        self.assertTrue(result['mergePending'])
        self.assertEqual((self.work / '代码.py').read_bytes(), before)
        self.assertEqual(self.git('rev-parse', 'HEAD'), args['expectedHead'])
        self.assertTrue(self.git('ls-files', '-u'))
        self.assertEqual((self.work / '.git/MERGE_HEAD').read_text().strip(), args['sourceSHA'])
        return args

    def resolve(self, choice='manual', text='resolved\n'):
        return self.result('conflictResolve', **self.args(), path='代码.py', choice=choice, text=text)

    def finish(self):
        return self.result('conflictContinue', **self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='Resolved merge')

    def test_text_resolution_continue_two_parents_and_reopen(self):
        source = self.start()
        first = self.session()
        self.assertEqual(self.session(), first)  # fresh repository handle, same persistent session
        detail = self.result('conflictFile', **self.args(), path='代码.py')
        self.assertIn('<<<<<<< CURRENT', detail['result'])
        self.assertIn('>>>>>>> INCOMING', detail['result'])
        self.assertFalse(self.call('conflictContinue', **self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='too early')['ok'])
        self.assertEqual(self.resolve()['resolved'], 1)
        (self.work / 'after-start.txt').write_text('keep me')
        self.finish()
        self.assertEqual((self.work / '代码.py').read_text(), 'resolved\n')
        self.assertEqual(self.git('show', '-s', '--format=%P', 'HEAD').split(), [source['expectedHead'], source['sourceSHA']])
        self.assertEqual((self.work / 'after-start.txt').read_text(), 'keep me')
        self.assertFalse(self.session()['active'])
        self.assertFalse((self.work / '.git/MERGE_HEAD').exists())
        self.assertEqual(self.git('show-ref', '--hash', first['recoveryRef']), source['expectedHead'])

    def test_abort_restores_exact_index_preserves_new_and_ignored_files(self):
        args = self.feature(conflict=True, diverge=True)
        index = (self.work / '.git/index').read_bytes()
        files = {p.name: p.read_bytes() for p in self.work.iterdir() if p.is_file()}
        self.result('mergeStart', **args)
        self.resolve('theirs')
        (self.work / 'after-start.txt').write_text('keep')
        (self.work / 'ignored').write_text('ignored keep')
        self.result('conflictAbort', **self.args())
        self.assertEqual((self.work / '.git/index').read_bytes(), index)
        for name, content in files.items():
            self.assertEqual((self.work / name).read_bytes(), content)
        self.assertEqual((self.work / 'after-start.txt').read_text(), 'keep')
        self.assertEqual((self.work / 'ignored').read_text(), 'ignored keep')
        self.assertEqual(self.git('rev-parse', 'HEAD'), args['expectedHead'])
        self.assertFalse(self.session()['active'])

    def test_old_fingerprint_and_external_index_edits_are_refused(self):
        self.start(); old = self.args(); self.resolve('ours')
        self.assertFalse(self.call('conflictResolve', **old, path='代码.py', choice='theirs')['ok'])
        (self.work / 'external.txt').write_text('external')
        self.git('add', 'external.txt')
        self.assertFalse(self.call('conflictStatus')['ok'])
        before = (self.work / '.git/index').read_bytes()
        self.assertFalse(self.call('conflictAbort', **old)['ok'])
        self.assertEqual((self.work / '.git/index').read_bytes(), before)

    def test_external_worktree_edit_refuses_both_continue_and_abort(self):
        self.start(); self.resolve('theirs')
        (self.work / '代码.py').write_text('external edit')
        args = self.args()
        self.assertFalse(self.call('conflictContinue', **args, authorName='Fixture', authorEmail='fixture@example.invalid', message='x')['ok'])
        self.assertFalse(self.call('conflictAbort', **args)['ok'])
        self.assertEqual((self.work / '代码.py').read_text(), 'external edit')

    def test_unresolved_markers_are_not_marked_resolved(self):
        self.start()
        detail = self.result('conflictFile', **self.args(), path='代码.py')
        self.assertFalse(self.call('conflictResolve', **self.args(), path='代码.py', choice='manual', text=detail['result'])['ok'])
        self.assertEqual(self.session()['resolved'], 0)

    def special_conflict(self, binary=False, rename=False, path='代码.py'):
        self.git('checkout', '-b', 'feature')
        if rename:
            self.git('mv', '代码.py', 'renamed.py')
        else:
            (self.work / path).write_bytes(b'incoming\x00binary' if binary else b'incoming\n')
        self.git('add', '-A'); self.git('commit', '-m', 'incoming')
        source = self.git('rev-parse', 'HEAD'); self.git('checkout', 'main')
        (self.work / path).write_bytes(b'current\x00binary' if binary else b'current modified\n')
        self.git('add', '-A'); self.git('commit', '-m', 'current')
        self.head = self.git('rev-parse', 'HEAD')
        args = dict(expectedHead=self.head, sourceRef='refs/heads/feature', sourceSHA=source,
                    method='ordinary', message='special conflict')
        self.result('mergeStart', **args)
        return args

    def test_binary_explicit_side_and_manual_rejected(self):
        self.special_conflict(binary=True)
        detail = self.result('conflictFile', **self.args(), path='代码.py')
        self.assertTrue(detail['binary'])
        self.assertFalse(self.call('conflictResolve', **self.args(), path='代码.py', choice='manual', text='invalid conversion')['ok'])
        self.resolve('theirs'); self.finish()
        self.assertEqual((self.work / '代码.py').read_bytes(), b'incoming\x00binary')

    def test_binary_checkout_transform_still_refused_without_writes(self):
        self.assert_binary_checkout_transform_refused('代码.py text eol=crlf\n')

    def test_binary_checkout_transform_with_ascii_pattern_refused_without_writes(self):
        self.assert_binary_checkout_transform_refused('*.py text eol=crlf\n')

    def test_binary_checkout_transform_utf8_85_and_ascii_whitespace_refused_without_writes(self):
        self.assert_binary_checkout_transform_refused(
            'before.py -text\r\n装.py\ttext\teol=crlf\r\nafter.py -text\r\n', path='装.py')

    def test_binary_checkout_transform_other_chinese_without_final_lf_refused_without_writes(self):
        self.assert_binary_checkout_transform_refused('文件.py text eol=crlf', path='文件.py')

    def test_binary_checkout_transform_nonbreaking_space_path_refused_without_writes(self):
        path = 'space\u00a0name.py'
        self.assert_binary_checkout_transform_refused(
            'before.py -text\n' + path + '\ttext eol=crlf\nlast.py -text', path=path)

    def assert_binary_checkout_transform_refused(self, attribute_line, path='代码.py'):
        if path != '代码.py':
            self.git('mv', '代码.py', path)
            self.git('commit', '-m', 'UTF-8 conflict path')
        args = self.special_conflict(binary=True, path=path)
        self.result('conflictAbort', **self.args())
        (self.work / '.gitattributes').write_bytes(attribute_line.encode('utf-8'))
        (self.work / path).write_bytes(b'current\x00binary\n')
        self.git('add', '-A'); self.git('commit', '-m', 'forced binary checkout transform')
        self.head = self.git('rev-parse', 'HEAD'); args['expectedHead'] = self.head
        # Preserve raw bytes: self.git() decodes and strips the LF under test.
        blob = subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=self.work)
        incoming = subprocess.check_output(['git', 'show', args['sourceSHA'] + ':' + path], cwd=self.work)
        attributes = self.git('check-attr', 'text', 'eol', '--', path).splitlines()
        status = self.git('status', '--porcelain')
        before = (self.work / path).read_bytes()
        diagnostics = dict(head=self.head, source=args['sourceSHA'], path=path, headBlobHex=blob.hex(),
                           incomingBlobHex=incoming.hex(), worktreeHex=before.hex(),
                           attributes=attributes, attributeLine=attribute_line,
                           status=status, gitVersion=self.git('--version'))
        print('BINARY_FILTER_FIXTURE ' + json.dumps(diagnostics, ensure_ascii=False, sort_keys=True), flush=True)
        self.assertEqual(blob, b'current\x00binary\n', diagnostics)
        self.assertEqual(attributes, [path + ': text: set', path + ': eol: crlf'], diagnostics)
        self.assertEqual(status, '', diagnostics)
        index = (self.work / '.git/index').read_bytes()
        reply = self.call('mergeStart', **args)
        print('BINARY_FILTER_REPLY ' + json.dumps(reply, ensure_ascii=False, sort_keys=True), flush=True)
        self.assertFalse(reply['ok'], dict(fixture=diagnostics, reply=reply))
        self.assertIn('checkout 过滤', reply['error'])
        self.assertEqual((self.work / path).read_bytes(), before)
        self.assertEqual((self.work / '.git/index').read_bytes(), index)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        self.assertFalse((self.work / '.git/repopocket-merge.json').exists())
        self.assertFalse((self.work / '.git/MERGE_HEAD').exists())

    def test_status_ignore_utf8_patterns_crlf_and_adjacent_rules_without_final_lf(self):
        ignored = ['代码.tmp', '装.tmp', '文件.tmp', 'space\u00a0name.tmp', 'ignored']
        visible = [path + '.keep' for path in ignored] + ['visible.tmp']
        rules = '\r\n'.join(ignored + ['visible.tmp', '!visible.tmp'])
        (self.work / '.gitignore').write_bytes(rules.encode('utf-8'))
        for path in ignored + visible:
            (self.work / path).write_bytes(b'keep bytes\n')
        self.assertEqual(self.git('check-ignore', '--', *ignored).splitlines(), ignored)
        before = {p.name: p.read_bytes() for p in self.work.iterdir() if p.is_file()}
        index = (self.work / '.git/index').read_bytes()
        status = self.result('status')
        self.assertEqual({item['path'] for item in status['files']}, {'.gitignore', *visible})
        self.assertEqual(status['staged'], [])
        self.assertEqual(status['head'], self.head)
        self.assertEqual({p.name: p.read_bytes() for p in self.work.iterdir() if p.is_file()}, before)
        self.assertEqual((self.work / '.git/index').read_bytes(), index)

    def test_rename_delete_difference_is_explicit_and_delete_choice_works(self):
        self.special_conflict(rename=True)
        s = self.session()
        self.assertEqual(s['files'][0]['path'], '代码.py')
        self.assertFalse(s['files'][0]['theirsExists'])
        self.resolve('theirs'); self.finish()
        self.assertFalse((self.work / '代码.py').exists())
        self.assertTrue((self.work / 'renamed.py').exists())
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_divergent_pull_starts_same_persistent_session_without_push(self):
        self.make_remote()
        peer = Path(self.temp.name) / 'synthetic-peer'
        self.git('clone', str(self.remote), str(peer))
        self.git('config', 'user.name', 'Peer', cwd=peer)
        self.git('config', 'user.email', 'peer@example.invalid', cwd=peer)
        (peer / '代码.py').write_text('incoming pull\n')
        self.git('add', '.', cwd=peer); self.git('commit', '-m', 'peer', cwd=peer)
        self.git('push', 'origin', 'main', cwd=peer)  # own temporary bare origin only
        remote_head = self.git('rev-parse', 'HEAD', cwd=self.remote)
        (self.work / '代码.py').write_text('local pull\n')
        self.git('add', '.'); self.git('commit', '-m', 'local')
        self.head = self.git('rev-parse', 'HEAD')
        reply = self.result('pull', expectedHead=self.head, expectedRemote=self.remote.as_uri())
        self.assertTrue(reply['mergePending'])
        self.assertEqual(self.session()['sourceRef'], 'refs/remotes/origin/main')
        self.assertEqual((self.work / '代码.py').read_text(), 'local pull\n')
        self.resolve('theirs'); self.finish()
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.remote), remote_head)
        self.assertEqual(self.git('show', '-s', '--format=%P', 'HEAD').split(), [self.head, remote_head])

    def kill_at(self, operation, args, stage):
        marker = self.work / '.git/repopocket-test-paused'
        marker.unlink(missing_ok=True)
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work), expectedRef='refs/heads/main', testCrashStage=stage)
        request.update(args)
        script = ('import ctypes,json,sys; lib=ctypes.CDLL(sys.argv[1]); '
                  'lib.rp_git_execute.argtypes=[ctypes.c_char_p,ctypes.c_char_p]; '
                  'lib.rp_git_execute.restype=ctypes.c_void_p; '
                  'lib.rp_git_execute(sys.argv[2].encode(),sys.argv[3].encode())')
        process = subprocess.Popen([sys.executable, '-c', script, self.library_path, operation, json.dumps(request)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists(), 'Production crash hook was not reached')
        finally:
            process.kill(); process.communicate(timeout=5)

    def test_killed_initial_index_install_is_recognized_and_abortable(self):
        args = self.feature(conflict=True, diverge=True)
        original = (self.work / '.git/index').read_bytes()
        self.kill_at('mergeStart', args, 'conflictBeforeIndex')
        self.assertTrue(self.result('status')['mergePending'])
        self.assertEqual(self.session()['resolved'], 0)
        self.result('conflictAbort', **self.args())
        self.assertEqual((self.work / '.git/index').read_bytes(), original)
        self.assertFalse(self.session()['active'])

    def test_killed_checkout_can_abort_without_removing_unrelated_new_file(self):
        self.start(); self.resolve('theirs')
        (self.work / 'new-after-merge').write_text('preserve')
        args = dict(self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='merge')
        self.kill_at('conflictContinue', args, 'conflictAfterCheckout')
        self.assertEqual(self.session()['phase'], 'continuing')
        self.result('conflictAbort', **self.args())
        self.assertEqual((self.work / '代码.py').read_text(), 'target content\n')
        self.assertEqual((self.work / 'new-after-merge').read_text(), 'preserve')

    def test_killed_after_publication_can_finish_but_not_abort_commit(self):
        self.start(); self.resolve('theirs')
        args = dict(self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='merge')
        self.kill_at('conflictContinue', args, 'conflictAfterPublish')
        new_head = self.git('rev-parse', 'HEAD')
        self.assertFalse(self.call('conflictAbort', **self.args())['ok'])
        self.finish()
        self.assertEqual(self.git('rev-parse', 'HEAD'), new_head)
        self.assertFalse(self.session()['active'])

    def race_before_lock(self, change):
        self.start(); self.resolve('theirs')
        request = dict(repository=str(self.work / '.git'), workdir=str(self.work), **self.args(),
                       authorName='Fixture', authorEmail='fixture@example.invalid', message='merge',
                       testCrashStage='conflictBeforeHeadLock', testResumeOnFile=True)
        marker = self.work / '.git/repopocket-test-paused'
        marker.unlink(missing_ok=True)
        script = ('import ctypes,json,sys; lib=ctypes.CDLL(sys.argv[1]); '
                  'lib.rp_git_execute.argtypes=[ctypes.c_char_p,ctypes.c_char_p]; '
                  'lib.rp_git_execute.restype=ctypes.c_void_p; '
                  'p=lib.rp_git_execute(b"conflictContinue",sys.argv[2].encode()); '
                  'print(ctypes.string_at(p).decode())')
        process = subprocess.Popen([sys.executable, '-c', script, self.library_path, json.dumps(request)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists(), 'Pre-lock production barrier was not reached')
            expected = change()
            (self.work / '.git/repopocket-test-resume').write_text('resume')
            output, error = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, error.decode())
            self.assertFalse(json.loads(output)['ok'])
            self.assertEqual(self.git('rev-parse', 'HEAD'), expected)
            self.assertTrue((self.work / '.git/repopocket-merge.json').exists())
        finally:
            if process.poll() is None:
                process.kill(); process.communicate(timeout=5)

    def test_same_tree_external_commit_between_preview_and_lock_is_not_overwritten(self):
        def change():
            before = self.git('rev-parse', 'HEAD')
            tree = self.git('rev-parse', 'HEAD^{tree}')
            after = self.git('commit-tree', tree, '-p', before, '-m', 'external same tree')
            self.git('update-ref', 'refs/heads/main', after, before)
            return after
        self.race_before_lock(change)

    def test_same_tree_external_branch_switch_between_preview_and_lock_is_refused(self):
        def change():
            self.git('branch', 'external-same', 'HEAD')
            self.git('symbolic-ref', 'HEAD', 'refs/heads/external-same')
            return self.git('rev-parse', 'HEAD')
        self.race_before_lock(change)
        self.assertEqual(self.git('symbolic-ref', 'HEAD'), 'refs/heads/external-same')

    def test_oid_written_owned_lock_before_ref_rename_can_continue(self):
        self.start(); self.resolve('theirs')
        args = dict(self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='merge')
        self.kill_at('conflictContinue', args, 'conflictBeforePublishRename')
        record = json.loads((self.work / '.git/repopocket-merge.json').read_text())
        lock = self.work / '.git/refs/heads/main.lock'
        self.assertEqual(lock.read_text(), record['newHead'] + '\n')
        self.assertEqual(self.git('rev-parse', 'HEAD'), record['oldHead'])
        self.finish()
        self.assertEqual(self.git('rev-parse', 'HEAD'), record['newHead'])
        self.assertFalse(self.session()['active'])

    def test_oid_written_owned_lock_before_ref_rename_can_abort(self):
        self.start(); self.resolve('theirs')
        args = dict(self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='merge')
        self.kill_at('conflictContinue', args, 'conflictBeforePublishRename')
        self.result('conflictAbort', **self.args())
        self.assertEqual((self.work / '代码.py').read_text(), 'target content\n')
        self.assertFalse(self.session()['active'])

    def test_unknown_oid_in_owned_lock_is_not_deleted(self):
        self.start(); self.resolve('theirs')
        args = dict(self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='merge')
        self.kill_at('conflictContinue', args, 'conflictBeforePublishRename')
        lock = self.work / '.git/refs/heads/main.lock'
        unknown = '0' * 40 + '\n'
        with lock.open('w') as output:
            output.write(unknown)  # same inode, wrong content must still be refused
        self.assertFalse(self.call('conflictContinue', **dict(self.args(), authorName='Fixture', authorEmail='fixture@example.invalid', message='merge'))['ok'])
        self.assertEqual(lock.read_text(), unknown)


if __name__ == '__main__':
    unittest.main()
