"""Mobile editor integration contracts and production UTF-16 edit fixtures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MobileEditorTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')

    def test_shared_editor_uses_native_find_and_guarded_edit_commands(self):
        view = self.source('SourceCodeView.swift')
        surface = self.source('SourceTextSurface.swift')
        self.assertIn('findRequest', view)
        self.assertIn('isFindInteractionEnabled = true', surface)
        self.assertIn('presentFindNavigator(showingReplace: textView.isEditable)', surface)
        self.assertIn('textView.markedTextRange == nil', surface)
        self.assertIn('SourceEditRules.newline', surface)
        self.assertIn('SourceEditRules.indent', surface)
        self.assertIn('undoManager?.undo()', surface)
        self.assertIn('undoManager?.redo()', surface)

    def test_local_save_stays_open_and_dirty_close_requires_a_choice(self):
        source = self.source('LocalProjectEditor.swift')
        self.assertIn('interactiveDismissDisabled(busy || dirty)', source)
        self.assertIn('保存后关闭', source)
        self.assertIn('放弃修改', source)
        self.assertIn('继续编辑', source)
        self.assertIn('originalText = value', source)
        self.assertIn('LocalGitFileAccess.fingerprint(Data(value.utf8))', source)
        self.assertNotIn('changed(); dismiss()', source)
        self.assertIn('新建文件', source)
        self.assertIn('新建文件夹', source)
        self.assertIn('LocalGitFileAccess.create', source)

    def test_name_search_does_not_download_workspace_or_accept_partial_tree(self):
        source = self.source('RepositoryFileSearch.swift')
        self.assertIn('DirectoryBrowserDestination', source)
        self.assertIn('FileView(', source)
        self.assertIn('!tree.truncated', source)
        self.assertIn('tree.tree.count <= 20000', source)
        self.assertIn('recursive', source)
        self.assertNotIn('fetchWorkspace(', source)
        self.assertIn('RepositoryFileSearchView', self.source('RepoPocketApp.swift'))

    def test_post_push_navigation_is_pinned_to_branch_and_sha(self):
        project = self.source('LocalProjectView.swift')
        self.assertIn('查看本次构建', project)
        self.assertIn('headSHA: build.sha', project)
        self.assertIn('sha: current.status.head', project)
        api = self.source('NativeRepositoryAPI.swift')
        self.assertIn('name: "head_sha", value: headSHA', api)
        runs = self.source('WorkflowViews.swift')
        self.assertIn('currentBranchOnly || !headSHA.isEmpty', runs)
        self.assertIn('headSHA: headSHA', runs)
        self.assertIn('尚未发现本次提交的运行', runs)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production Swift edit fixtures execute on macOS')
    def test_utf16_indentation_selection_and_line_endings(self):
        fixture = r'''
import Foundation
@main struct Fixture {
 static func main() {
  func apply(_ text: String, _ edit: SourceTextEdit) -> String {
   (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
  }
  let unicode = "    中文😀"
  let caret = NSRange(location: (unicode as NSString).length, length: 0)
  let newline = SourceEditRules.newline(unicode, selection: caret)!
  precondition(apply(unicode, newline) == "    中文😀\n    ")
  precondition(newline.selection.location == caret.location + 5)
  let crlf = "  a\r\n  b"
  let crlfEdit = SourceEditRules.newline(crlf, selection: NSRange(location: 8, length: 0))!
  precondition(apply(crlf, crlfEdit) == "  a\r\n  b\r\n  ")
  let tabs = SourceEditRules.newline("\tlet x", selection: NSRange(location: 6, length: 0))!
  precondition(tabs.replacement == "\n\t")
  let plain = "中文😀\nnext"
  let selection = NSRange(location: 0, length: 5)
  let indented = SourceEditRules.indent(plain, selection: selection, unindent: false)!
  precondition(apply(plain, indented) == "    中文😀\nnext")
  precondition(indented.selection == NSRange(location: 4, length: 5))
  let reduced = SourceEditRules.indent("  a\r\n\tb\r\nc", selection: NSRange(location: 1, length: 8), unindent: true)!
  precondition(apply("  a\r\n\tb\r\nc", reduced) == "a\r\nb\r\nc")
  precondition(reduced.selection == NSRange(location: 0, length: 6))
  let end = SourceEditRules.indent("x\n", selection: NSRange(location: 2, length: 0), unindent: false)!
  precondition(apply("x\n", end) == "x\n    ")
  precondition(SourceEditRules.indent("x", selection: NSRange(location: 0, length: 0), unindent: true) == nil)
  precondition(SourceEditRules.newline("😀", selection: NSRange(location: 1, length: 0)) == nil)
  precondition(SourceEditRules.indent("😀", selection: NSRange(location: 0, length: 1), unindent: false) == nil)
  precondition(SourceEditRules.newline("x", selection: NSRange(location: NSNotFound, length: 1)) == nil)
  precondition(SourceEditRules.indent("x", selection: NSRange(location: 9, length: 0), unindent: false) == nil)
  print("PASS UTF-16 selections, emoji, CRLF, tabs, multiline indentation and bounds")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / 'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            output = str(Path(directory) / 'check')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT / 'RepoPocket/SourceEditRules.swift'), str(main), '-o', output], check=True)
            subprocess.run([output], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
