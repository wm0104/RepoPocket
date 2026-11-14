"""Account authorization pages use connected native rows without changing auth work."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'RepoPocket'


class CompactAccountGroupsTests(unittest.TestCase):
    def test_account_list_and_authorization_share_one_section(self):
        text = (ROOT / 'AccountManagement.swift').read_text(encoding='utf-8')
        page = text.split('var body: some View {', 1)[1]
        self.assertEqual(len(re.findall(r'\bSection\s*(?:\(|\{)', page)), 1)
        self.assertIn('Section("账号")', page)
        self.assertIn('Text("尚无已验证账号").softGroupedRow(top: true)', page)
        self.assertIn('.softGroupedRow(top: account.id == accounts.first?.id)', page)
        self.assertIn('DeviceOAuthView(api: api) }.softGroupedRow()', page)
        self.assertNotIn('bottom: account.id == accounts.last?.id', page)
        self.assertIn('Text("仅移除本机凭据，不会删除 GitHub 账号、远端仓库或本地工作区。").font(.caption).softGroupedRow(bottom: error.isEmpty)', page)
        self.assertIn('if !error.isEmpty { Text(error).font(.caption).softGroupedRow(bottom: true) }', page)

    def test_oauth_setup_is_inside_the_same_native_rows(self):
        page = (ROOT / 'DeviceOAuthView.swift').read_text(encoding='utf-8')
        self.assertEqual(len(re.findall(r'\bSection\s*(?:\(|\{)', page)), 1)
        self.assertIn('Section("GitHub 浏览器授权")', page)
        self.assertEqual(page.count('SoftGroupRows {'), 1)
        self.assertIn('SoftGroupRow("setup-heading") { Text("首次配置")', page)
        for row in ['client', 'scope', 'follow', 'profile', 'help', 'message', 'setup', 'apps', 'docs']:
            self.assertIn(f'SoftGroupRow("{row}")', page)
        self.assertLess(page.index('SoftGroupRow("message")'), page.index('SoftGroupRow("setup-heading")'))
        self.assertLess(page.index('SoftGroupRow("setup-heading")'), page.index('SoftGroupRow("docs")'))


if __name__ == '__main__':
    unittest.main()
