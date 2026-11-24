"""Host UI contracts: source structure + executable state fixtures, NOT Swift/visual tests."""
from pathlib import Path
import ast
import itertools
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(name):
    return (ROOT / 'RepoPocket' / (name + '.swift')).read_text()

def block(text, marker):
    start = text.index('{', text.index(marker))
    depth = 1
    for end in range(start + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if not depth:
            return text[start + 1:end]
    raise AssertionError('unbalanced block: ' + marker)

def boolean(expression, values):
    """Evaluate only the boolean subset used in these Swift UI gates, from real source."""
    for term in sorted(values, key=len, reverse=True):
        expression = expression.replace(term, str(values[term]))
    expression = expression.replace('||', ' or ').replace('&&', ' and ').replace('!', ' not ').strip()
    tree = ast.parse('(' + expression + ')', mode='eval')
    allowed = (ast.Expression, ast.BoolOp, ast.UnaryOp, ast.And, ast.Or, ast.Not, ast.Constant, ast.Load)
    if not all(isinstance(node, allowed) for node in ast.walk(tree)):
        raise AssertionError('unsupported UI predicate: ' + expression)
    return eval(compile(tree, '<Swift boolean UI fixture>', 'eval'), {'__builtins__': {}})

class GlobalWorkspaceUI(unittest.TestCase):
    def test_author_missing_predicate_and_sheet_lifecycle(self):
        p = source('LocalProjectView')
        predicate = block(p, 'private var authorIncomplete: Bool')
        self.assertIn('authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||', predicate)
        self.assertIn('authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty', predicate)
        for name, email, incomplete in [('', '', True), (' \n', 'a@b', True),
                                       ('A', '\t', True), (' A ', ' a@b ', False)]:
            values = {key + '.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty': not value.strip()
                      for key, value in [('authorName', name), ('authorEmail', email)]}
            self.assertEqual(boolean(predicate, values), incomplete)
            expansion = re.search(r'if (authorExpanded[^\n{]+)\{', p).group(1)
            for user_expanded in (False, True):
                self.assertEqual(boolean(expansion, {'authorExpanded': user_expanded, 'authorIncomplete': incomplete}),
                                 incomplete or user_expanded)
        form = block(p, 'private var commitForm: some View')
        self.assertIn('if authorExpanded || authorIncomplete', form)
        self.assertIn('SoftGroupRow("author-summary")', form)
        self.assertIn('authorName + " · " + authorEmail', form)
        self.assertIn('.onAppear { authorExpanded = authorIncomplete }', form)
        self.assertIn('pendingCommit = true; sheet = nil', form)
        self.assertIn('.sheet(item: $sheet, onDismiss: finishCommit)', p)
        self.assertIn('guard pendingCommit,valid,let current=state.snapshot', block(p, 'private func finishCommit('))
        self.assertIn('authorIncomplete', form[form.index('.disabled('):])

    def test_local_unique_info_and_deb_diff(self):
        p = source('LocalProjectView')
        self.assertEqual(p.count('sheet = .info'), 1)
        self.assertNotIn('查看远端设置…', p)
        self.assertIn('没有可用的 GitHub HTTPS 远端', p)
        self.assertNotIn('Button("查看变化")', p)
        self.assertIn('Button { sheet = .diff(file.path) }', p)
        self.assertNotIn('Button("编辑包信息")', p)
        self.assertIn('NavigationLink("关联 GitHub 仓库…")', p)

    def test_import_advanced_details_do_not_hide_core_or_warnings(self):
        p = source('LocalProjectImportView')
        advanced = block(p, 'if advancedExpanded')
        details = block(p, 'if importDetailsExpanded')
        self.assertIn('已知基准 SHA', advanced)
        self.assertIn('folder?.directPath', details)
        self.assertIn('preview.head', details)
        for key in ('Text("分支：" + preview.branch)', '新子文件夹名称', '存在冲突、受限文件或未完成的 Git 操作',
                    '确认关联原目录', 'ProgressView("处理中', 'if !message.isEmpty', 'preview.canAssociate'):
            self.assertIn(key, p)
            self.assertNotIn(key, details)
            self.assertNotIn(key, advanced)
        self.assertIn('DisclosureGroup("手动输入仓库地址"', p)
        self.assertIn('VStack(alignment: .leading', p)  # One content root for multi-field disclosure.
        self.assertIn('latest.canAssociate', p)
        gate = re.search(r'\.disabled\((busy \|\| preview != nil)\)', p).group(1)
        error_gate = re.search(r'if (!message.isEmpty) \{', p).group(1)
        for busy, preview, error in itertools.product((False, True), repeat=3):
            self.assertEqual(boolean(gate, {'busy': busy, 'preview != nil': preview}), busy or preview)
            self.assertEqual(boolean(error_gate, {'message.isEmpty': not error}), error)
        self.assertIn('folder?.directPath != nil || preview != nil', p)
        for path, has_preview in itertools.product((False, True), repeat=2):
            gate = re.search(r'if (folder\?\.directPath != nil \|\| preview != nil)', p).group(1)
            self.assertEqual(boolean(gate, {'folder?.directPath != nil': path, 'preview != nil': has_preview}),
                             path or has_preview)
        for state in ('advancedExpanded', 'importDetailsExpanded'):
            self.assertIn('@State private var ' + state + ' = false', p)
            self.assertIn('UIRules.withoutAnimation { ' + state + '.toggle() }', p)

    def test_merge_lists_default_open_and_safety_outside_collapses(self):
        m = source('LocalGitMerge')
        for state in ('mergeCommitsExpanded', 'mergeFilesExpanded'):
            self.assertIn('@State private var ' + state + ' = true', m)
            self.assertIn('UIRules.withoutAnimation { ' + state + '.toggle() }', m)
            collapsed = block(m, 'if ' + state)
            self.assertNotIn('SoftGroupRow("confirm")', collapsed)
            self.assertNotIn('conflict-help', collapsed)
        # Conflicts can now start an explicit persistent resolution session;
        # a truncated conflict list must still block confirmation.
        self.assertIn('!preview.conflictsTruncated, preview.method == method', m)
        self.assertIn('preview.conflicts.isEmpty ? "mergeBranch" : "mergeStart"', m)
        self.assertIn('confirmation = preview; confirming = true', m)
        self.assertIn('LocalGitConflictView(', m)
        self.assertIn('guard valid, !state.busy', m)
        self.assertIn('if !state.failure.isEmpty', m)
        self.assertIn('确认合并到当前分支？', m)

class OperationFeedbackTests(unittest.TestCase):
    def test_local_git_details_and_pending_are_not_success(self):
        for file in ('LocalGitImportUI', 'LocalGitStageView', 'LocalGitBranchManagement',
                     'LocalGitConflictView', 'LocalGitHistoryActions', 'LocalGitMerge', 'LocalProjectView'):
            text = source(file)
            self.assertIn('AppFeedback.show(', text, file)
            self.assertIn('session: ', text, file)
        self.assertIn('尚未推送', source('LocalGitStageView'))
        self.assertIn('恢复引用', source('LocalGitHistoryActions'))
        merge = source('LocalGitMerge').split('private func apply(', 1)[1]
        self.assertLess(merge.index('if mergePending'), merge.index('AppFeedback.show('))
        self.assertLess(merge.index('return\n'), merge.index('AppFeedback.show('))
        project = source('LocalProjectView').split('private func sync(', 1)[1]
        self.assertLess(project.index('state.fresh, state.error.isEmpty'), project.index('AppFeedback.show('))
        self.assertIn('if completed', project)

    def test_remote_and_copy_feedback_is_explicit(self):
        for file, title in (('RepositorySections', '复刻请求已接受'), ('RepositoryForkMenu', '复刻请求已接受'),
                            ('DesktopViews', '远端分支已创建'), ('UploadView', '队列已提交到 GitHub'),
                            ('DiscoveryViews', '链接已复制')):
            self.assertIn('AppFeedback.show("' + title + '", api: api)', source(file))
        deletion = source('RepositoryDeletionView')
        self.assertIn('AppFeedback.show("远端仓库已删除，本地工作区未删除", api: api)', deletion)
        self.assertNotIn('api.message = message', deletion)
        self.assertIn('最后确认：永久删除远端仓库', deletion)
        self.assertIn('此链接没有可用的网页地址', source('DiscoveryViews'))
        self.assertIn('if error.isEmpty { AppFeedback.show(', source('SocialAccountsView'))
        self.assertEqual(source('RepositoryCollectionViews').count('if verified, succeeded == pending.count, error.isEmpty {'), 2)

if __name__ == '__main__':
    unittest.main()
