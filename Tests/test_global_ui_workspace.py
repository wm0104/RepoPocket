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
    def test_workspace_technical_rows_are_dynamic_siblings(self):
        w = source('WorkspaceView')
        body = block(w, 'private func bindingSection(')
        self.assertIn('SoftGroupRows', body)
        details = block(body, 'if technicalDetailsExpanded')
        for key in ('folder.path', '扫描时忽略 .git', 'binding.head', 'remoteAuthorDate',
                    'remoteCommitterDate', 'lastChecked', 'lastPulled'):
            self.assertIn(key, details)
        self.assertEqual(body.count('Text("实际工作目录：" + folder.path)'), 1)
        self.assertNotIn('Text("绝对路径："', body)
        self.assertIn('复制实际工作目录路径', details)
        self.assertIn('UIRules.withoutAnimation { technicalDetailsExpanded.toggle() }', body)
        for text in ('TextField("仓库链接"', 'TextField("分支', 'TextField("原始 ZIP', '验证副本并关联当前远端'):
            self.assertIn(text, body)
            self.assertNotIn(text, details)
        for text in ('重命名实际目录', '检查更新', '删除本地工作区'):
            self.assertIn(text, body)  # Detail sheet retains its own management context.

    def test_workspace_unique_route_and_safety(self):
        w = source('WorkspaceView')
        menu = block(w, 'private func workspaceManagement(')
        self.assertIn('binding == nil ? "associate" : "details"', menu)
        self.assertEqual(menu.count('showAssociation = true'), 1)
        self.assertEqual(menu.count('showDetails = true'), 1)
        self.assertEqual(menu.count('title: "工作区详情"'), 0)
        self.assertIn('!busy && api.isCurrentSession', menu)
        self.assertIn('self.folder == folder', menu)
        for key in ('$confirmDelete', '$confirmDirtyDelete', 'if !linked'):
            self.assertIn(key, w)
        route_ids = re.search(r'id: binding == nil \? "([^"]+)" : "([^"]+)"', menu).groups()
        gate = re.search(r'enabled: ([^,]+), items:', menu).group(1)
        for linked, associated, busy, current in itertools.product((False, True), repeat=4):
            self.assertEqual(route_ids[int(associated)], 'details' if associated else 'associate')
            self.assertEqual(boolean(gate, {'busy': busy, 'api.isCurrentSession': current}), not busy and current)

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
        self.assertIn('Button("编辑包信息")', p)
        self.assertIn('NavigationLink("关联 GitHub 仓库…")', p)

    def test_import_advanced_details_do_not_hide_core_or_warnings(self):
        p = source('LocalProjectImportView')
        advanced = block(p, 'if advancedExpanded')
        details = block(p, 'if importDetailsExpanded')
        self.assertIn('已知基准 SHA', advanced)
        self.assertIn('folder?.directPath', details)
        self.assertIn('preview.head', details)
        for key in ('Text("分支：" + preview.branch)', '新子文件夹名称', '已有暂存或未完成 Git 操作',
                    '确认关联原目录', 'ProgressView("处理中', 'if !message.isEmpty', 'preview.canCommit'):
            self.assertIn(key, p)
            self.assertNotIn(key, details)
            self.assertNotIn(key, advanced)
        self.assertIn('DisclosureGroup("手动输入仓库地址"', p)
        self.assertIn('VStack(alignment: .leading', p)  # One content root for multi-field disclosure.
        self.assertIn('preview.files.contains(where: { !$0.blocked.isEmpty })', p)
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

if __name__ == '__main__':
    unittest.main()
