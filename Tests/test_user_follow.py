"""Execute production follow rules, API methods and shared store against isolated requests."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]

class UserFollowTests(unittest.TestCase):
    def test_shared_profile_and_single_attachment_presenter(self):
        profile = (ROOT/'RepoPocket/DiscoveryViews.swift').read_text()
        row = (ROOT/'RepoPocket/UserFollowRow.swift').read_text()
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        self.assertIn('profile.type == "User"', profile)
        self.assertIn('viewer != login.lowercased()', profile)
        self.assertIn('SoftGroupRow("follow") { UserFollowRow(', profile)
        self.assertIn('followed ? "取消关注" : "关注"', row)
        self.assertIn('if let followed = store.known(login)', row)
        self.assertIn('attempted = false', row)
        self.assertIn('self?.follows.invalidate()', api)
        transport = api.split('    func followRequest(',1)[1].split('    private func managedJSON',1)[0]
        self.assertIn('checking: method == "GET"', transport)
        self.assertIn('delegate: OfficialUpdateRedirectPolicy()', transport)
        self.assertNotIn('requireWriteAccess', transport)
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        attachment = ui.split('ForEach(state.assets) { asset in',1)[1].split('if state.assets.isEmpty',1)[0]
        self.assertEqual(attachment.count('Menu {'),1)
        self.assertNotIn('ellipsis', attachment)
        self.assertNotIn('assetAction', ui.replace('assetActions', ''))
        self.assertIn('.contentShape(Rectangle())', attachment)
        self.assertIn('.listRowInsets(EdgeInsets())', attachment)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native follow/API regressions run on macOS')
    def test_production_follow_requests_and_state(self):
        github = (ROOT/'RepoPocket/GitHub.swift').read_text()
        methods = github.split('    func followIdentity()',1)[1].split('    private func managedJSON',1)[0]
        methods = '    func followIdentity()' + methods
        request = github.split('    private func request(',1)[1].split('    // Public official update metadata',1)[0]
        request = '    private func request(' + request
        fixture = (ROOT/'Tests/Fixtures/UserFollowHarness.swift').read_text()
        fixture = fixture.replace('// PRODUCTION_API', methods + request)
        fixture = fixture.replace('// PRODUCTION_STORE', (ROOT/'RepoPocket/UserFollow.swift').read_text())
        fixture = fixture.replace('// PRODUCTION_OAUTH_RULES', (ROOT/'RepoPocket/DeviceOAuth.swift').read_text().split('enum DeviceOAuthRules {',1)[1].split('final class DeviceOAuthRedirectPolicy',1)[0])
        fixture = fixture.replace('// BEGIN_OAUTH_RULES', 'enum DeviceOAuthRules {')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'; path.write_text(fixture)
            subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True,timeout=30)

if __name__ == '__main__': unittest.main()
