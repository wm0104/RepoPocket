from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
import subprocess, tempfile

g = Path(REPO_ROOT, 'RepoPocket/GitHub.swift').read_text()
accounts = Path(REPO_ROOT, 'RepoPocket/GitHubAccounts.swift').read_text()
ui = Path(REPO_ROOT, 'RepoPocket/RepoPocketApp.swift').read_text()
avatar = Path(REPO_ROOT, 'RepoPocket/RepositoryUI.swift').read_text()
# Compile the production account store with an in-memory Keychain adapter.
store = accounts.replace('import Security\n', '')
models = g[g.index('struct User:'):g.index('struct Entry:')]
source = '''import Foundation
// Test adapter: production AccountStore calls the real per-account Keychain in-app.
enum CredentialStore {
    static var tokens: [String: String] = [:]
    static func clear(account: String) { tokens.removeValue(forKey: account) }
}
''' + store + models + r'''
UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
UserDefaults.standard.removeObject(forKey: AccountStore.activeKey)
let first = GitHubAccount(id: "100", login: "alice", avatarURL: "https://avatars.githubusercontent.com/u/100")
let second = GitHubAccount(id: "200", login: "bob", avatarURL: nil)
try AccountStore.record(first)
try AccountStore.record(second)
CredentialStore.tokens = [first.id: "fixture-alpha", second.id: "fixture-beta"]
AccountStore.activate(first.id)
precondition(CredentialStore.tokens[AccountStore.activeID] == "fixture-alpha")
let oldGeneration = AccountStore.generation
AccountStore.activate(second.id)
precondition(AccountStore.generation != oldGeneration)
precondition(CredentialStore.tokens[AccountStore.activeID] == "fixture-beta")
try AccountStore.record(second)
precondition(AccountStore.accounts.count == 2)
let metadata = String(data: UserDefaults.standard.data(forKey: AccountStore.accountsKey)!, encoding: .utf8)!
precondition(!metadata.contains("fixture-alpha") && !metadata.contains("fixture-beta"))
AccountStore.remove(second.id)
precondition(AccountStore.activeID == first.id && CredentialStore.tokens[second.id] == nil)
precondition(CredentialStore.tokens[first.id] == "fixture-alpha")
let raw = #"{"id":7,"full_name":"organization/tool","name":"tool","description":null,"default_branch":"main","html_url":"https://github.com/organization/tool","private":true,"updated_at":"2026-10-10T00:00:00Z","owner":{"id":9,"login":"organization","avatar_url":"https://avatars.githubusercontent.com/u/9"}}"#
let repo = try JSONDecoder().decode(Repository.self, from: Data(raw.utf8))
precondition(repo.owner?.login == "organization" && repo.private == true && repo.default_branch == "main")
let sparse = #"{"id":7,"full_name":"organization/tool","name":"tool","description":null,"html_url":"https://github.com/organization/tool"}"#
let legacy = try JSONDecoder().decode(Repository.self, from: Data(sparse.utf8))
precondition(legacy.owner == nil && legacy.private == nil)
AccountStore.remove(first.id)
UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
UserDefaults.standard.removeObject(forKey: AccountStore.activeKey)
print("PASS account switching/removal/metadata isolation and repository/avatar decoding")
'''
assert '"user:" + account' in g
assert 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in g
assert 'CredentialStore.read(account: accountID)' in g
assert 'AccountStore.activeID == accountID' in g
add = g[g.index('    func addAccount'):g.index('    func repositories')]
assert add.index('try check(') < add.index('try CredentialStore.save(')
assert '.id(accountID)' in ui and '.githubAccountChanged' in ui
assert 'avatars.githubusercontent.com' in Path(REPO_ROOT, 'RepoPocket/RepositoryPresentationRules.swift').read_text() and 'NSCache<NSURL, UIImage>' in avatar
assert 'Authorization' not in avatar and 'URLCache' in avatar
for line in (g + accounts + avatar).splitlines():
    assert not ('print(' in line or 'NSLog(' in line)
print('PASS Keychain/API/UI source contracts; no credential logging or authenticated avatars')
assert 'AccountStore.generation == accountGeneration' in g
assert 'session.invalidateAndCancel()' in g
assert 'AccountStore.generation' in ui
assert 'completionHandler(nil)' in avatar
assert 'configuration.urlCredentialStorage = nil' in avatar
assert 'configuration.httpCookieStorage = nil' in avatar
assert 'try ensureActiveAccount()' in g
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(source)
    subprocess.run(['swiftc', str(path), '-o', directory + '/tests'], check=True)
    subprocess.run([directory + '/tests'], check=True)
