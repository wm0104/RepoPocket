"""Remote branch rename: create the new ref before deleting the old one, never force."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / 'RepoPocket/GitHub.swift').read_text()
VIEW = (ROOT / 'RepoPocket/DesktopViews.swift').read_text()


def body(start, end):
    assert start in API, start
    return API.split(start, 1)[1].split(end, 1)[0]


class RemoteRenameContracts(unittest.TestCase):
    def test_rename_creates_then_deletes_with_existing_guards(self):
        rename = body('    func renameBranch(', '\n    func deleteBranch(')
        create = rename.index('"/git/refs", method: "POST"')
        delete = rename.index('try await deleteBranch(')
        self.assertLess(create, delete, 'commits must exist under the new ref before the old one is removed')
        for token in ('DesktopRules.validBranch(newName)', 'newName != name',
                      'info.permissions?.push == true', 'name != defaultBranch',
                      'target.protected == false', 'target.commit?.sha == expectedHead',
                      '同名远端分支已存在', '两个分支都保留'):
            self.assertIn(token, rename)
        self.assertNotIn('force: true', rename)
        self.assertNotIn('method: "PATCH"', rename)

    def test_view_exposes_long_press_rename_with_explicit_warning(self):
        self.assertIn('Label("重命名 GitHub 远端分支"', VIEW)
        self.assertIn('Label("删除 GitHub 远端分支"', VIEW)
        alert = VIEW.split('.alert("重命名 GitHub 远端分支"', 1)[1].split('} message:', 1)[0]
        self.assertIn('TextField(', alert)
        self.assertIn('DesktopRules.validBranch(name)', alert)
        message = VIEW.split('.alert("重命名 GitHub 远端分支"', 1)[1].split('.confirmationDialog("删除 GitHub 远端分支？"', 1)[0]
        self.assertIn('默认分支', message)
        self.assertIn('Pull Request', message)
        self.assertIn('本地 Git 跟踪不会自动改名', message)
        self.assertIn('current == target.name', VIEW)
        self.assertIn('select(newName)', VIEW)


if __name__ == '__main__':
    unittest.main()
