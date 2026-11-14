"""Production decoding regression tests; Swift execution requires the CI Apple runner."""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import shutil
import subprocess
import tempfile
import unittest


github = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
ui = Path(REPO_ROOT, 'RepoPocket/RepositoryUI.swift').read_text()
app = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()


class RepositoryStatisticsTests(unittest.TestCase):
    def test_optional_real_api_fields_and_shared_ui(self):
        for field in ('stargazers_count', 'forks_count'):
            self.assertIn(f'let {field}: Int?', github)
            self.assertIn(f'= repository.{field}', ui)
            self.assertNotIn(f'repository.{field} ?? 0', ui)
        self.assertIn('RepositoryStatistics(repository: repository)', ui)
        self.assertIn('RepositoryCard(repository: repositoryInfo, account: api.login, api: api, descriptionLineLimit: nil, copyLinkContextMenu: false)', app)
        self.assertIn('let info = try await api.repository(repo)', app)
        self.assertIn('repositoryInfo = nil', app)
        self.assertIn('try await decoded(Repository.self, Self.repoPath(repo))', github)

    def test_language_date_and_profile_contracts(self):
        self.assertIn('let language: String?', github)
        self.assertIn('repository.language', ui)
        self.assertNotIn('ISO8601DateFormatter', ui)
        self.assertNotIn('updated_at', ui)
        for field in ('followers', 'following'):
            self.assertIn(f'let {field}: Int?', github)
            self.assertIn(f'if let {field} = api.profile?.{field}', app)
            self.assertNotIn(f'api.profile?.{field} ?? 0', app)
        self.assertIn('GitHubAvatar(url: api.profile?.avatar_url ?? savedAccount?.avatarURL, size: 56)', app)
        self.assertIn('try ensureActiveAccount()\n        login = user.login; avatarURL = user.avatar_url; profile = user', github)
        self.assertIn('SecureField("粘贴你自己的 Token"', Path(REPO_ROOT, 'RepoPocket/AccountManagement.swift').read_text())

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable; run on macOS Actions')
    def test_production_decoding(self):
        models = github[github.index('struct User:'):github.index('struct Entry:')]
        source = 'import Foundation\n' + models + r'''
let base = #"{"id":7,"full_name":"organization/tool","name":"tool","html_url":"https://github.com/organization/tool"}"#
func decode(_ fields: String) throws -> Repository {
    let json = String(base.dropLast()) + fields + "}"
    return try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
}
let legacy = try decode("")
precondition(legacy.stargazers_count == nil && legacy.forks_count == nil)
precondition(legacy.fork == nil && legacy.parent == nil)
let forked = try decode(",\"fork\":true,\"parent\":{\"full_name\":\"middle/tool\"},\"source\":{\"full_name\":\"root/tool\"}")
precondition(forked.parent?.full_name == "middle/tool" && forked.fork == true)
let nulls = try decode(",\"stargazers_count\":null,\"forks_count\":null")
precondition(nulls.stargazers_count == nil && nulls.forks_count == nil)
let populated = try decode(",\"stargazers_count\":1234,\"forks_count\":56")
precondition(populated.stargazers_count == 1234 && populated.forks_count == 56)
let zero = try decode(",\"stargazers_count\":0,\"forks_count\":0")
precondition(zero.stargazers_count == 0 && zero.forks_count == 0)
let partial = try decode(",\"stargazers_count\":8")
precondition(partial.stargazers_count == 8 && partial.forks_count == nil)
let language = try decode(",\"language\":\"Swift\"")
precondition(language.language == "Swift" && legacy.language == nil)
let user = try JSONDecoder().decode(User.self, from: Data(#"{"login":"alice","name":"Alice","followers":123,"following":45}"#.utf8))
precondition(user.name == "Alice" && user.followers == 123 && user.following == 45)
let sparseUser = try JSONDecoder().decode(User.self, from: Data(#"{"login":"alice"}"#.utf8))
precondition(sparseUser.name == nil && sparseUser.followers == nil && sparseUser.following == nil)
let date = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")!
let shortDate = date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month(.twoDigits).day(.twoDigits))
precondition(shortDate.contains("2026") && !shortDate.contains("Oct"))
print("PASS production repository and profile decoding: legacy, null, real counts, zero, partial, language, Chinese date")
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'main.swift'
            path.write_text(source)
            executable = str(Path(directory) / 'tests')
            subprocess.run(['swiftc', str(path), '-o', executable], check=True)
            subprocess.run([executable], check=True)


if __name__ == '__main__':
    unittest.main()
