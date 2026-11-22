"""Replay real device authorization and credential validation at the HTTP boundary."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def production_program(linux=False):
    github = (ROOT / 'RepoPocket/GitHub.swift').read_text(encoding='utf-8')
    program = (ROOT / 'Tests/Fixtures/OAuthCompletionHarness.swift').read_text(encoding='utf-8').split('@main struct OAuthCompletionTests', 1)[0]
    sources = {
        '// PRODUCTION_ERRORS': 'struct AppError:' + github.split('struct AppError:', 1)[1].split('enum CredentialStore', 1)[0],
        '// PRODUCTION_ACCOUNTS': (ROOT / 'RepoPocket/GitHubAccounts.swift').read_text(encoding='utf-8').replace('import Security\n', ''),
        '// PRODUCTION_USER': 'struct User:' + github.split('struct User:', 1)[1].split('struct RepoAccess:', 1)[0] + 'struct GitHubMessage: Decodable { let message: String }',
        '// PRODUCTION_PRESENTATION': '',
        '// PRODUCTION_REDIRECT': (ROOT / 'RepoPocket/OfficialUpdateRedirectPolicy.swift').read_text(encoding='utf-8'),
        '// PRODUCTION_CHECK': '    private func ensureActiveAccount()' + github.split('    private func ensureActiveAccount()', 1)[1].split('    private func operation(', 1)[0],
        '// PRODUCTION_ACCOUNT_SAVE': '    var oauthScopes:' + github.split('    var oauthScopes:', 1)[1].split('    func repositories()', 1)[0],
        '// PRODUCTION_DEVICE_OAUTH': (ROOT / 'RepoPocket/DeviceOAuth.swift').read_text(encoding='utf-8'),
    }
    for marker, source in sources.items():
        assert program.count(marker) == 1, marker
        program = program.replace(marker, source)
    if linux:
        program = 'import FoundationNetworking\nimport Glibc\nprotocol ObservableObject: AnyObject {}\n@propertyWrapper struct Published<Value> { var wrappedValue: Value; init(wrappedValue: Value) { self.wrappedValue = wrappedValue } }\n' + program.replace('import Combine', '')
    return program + (ROOT / 'Tests/Fixtures/OAuthLoginRegressionHarness.swift').read_text(encoding='utf-8')


class OAuthLoginTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'production Swift replay runs on Apple CI or explicit Linux probe')
    def test_first_login_and_additional_account_with_social_permission(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'main.swift'
            source.write_text(production_program(), encoding='utf-8')
            binary = Path(folder) / 'oauth-login'
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
