"""Editor migration must keep remote submit lifecycle locked and preserve guarded saves."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SharedEditorLifecycleTests(unittest.TestCase):
    def test_remote_editor_is_locked_while_submitting(self):
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        editor = app.split('    private var editor: some View {', 1)[1].split('    private func read(', 1)[0]
        self.assertRegex(editor, r'SourceCodeEditor\(text: \$text, filename: entry\.path\)\s*\.disabled\(busy\)')
        self.assertIn('.interactiveDismissDisabled(busy)', editor)

    def test_local_editor_keeps_read_only_and_dirty_close_guards(self):
        local = (ROOT/'RepoPocket/LocalProjectEditor.swift').read_text()
        self.assertIn('readOnly: !editing).disabled(busy)', local)
        self.assertIn('.interactiveDismissDisabled(busy || dirty)', local)
        for choice in ['保存后关闭', '放弃修改', '继续编辑']:
            self.assertIn(choice, local)
        self.assertIn('expected: expected', local)

    def test_remote_save_keeps_permissions_and_original_sha(self):
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        save = app.split('    private func save() async {', 1)[1].split('    private func remove()', 1)[0]
        self.assertIn('guard writable, !busy, !currentSHA.isEmpty', save)
        self.assertIn('try await api.requireWriteAccess(repo)', save)
        self.assertIn('sha: currentSHA', save)
        self.assertIn('text.utf8.count <= SourceTextRules.byteLimit', save)

if __name__ == '__main__':
    unittest.main()
