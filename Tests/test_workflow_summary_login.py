from pathlib import Path
import json
from contextlib import contextmanager
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'RepoPocket/WorkflowSummaryLogin.swift'
CACHE = ROOT.parent


@contextmanager
def temporary_folder():
    # File Provider mounts do not reliably support shutil's fd-based rmtree.
    folder = Path(tempfile.mkdtemp(dir=CACHE))
    try:
        yield folder
    finally:
        for child in folder.iterdir():
            child.unlink()
        folder.rmdir()


class SummaryLoginTests(unittest.TestCase):
    def source(self):
        self.assertTrue(BRIDGE.exists(), 'authenticated extraction bridge is missing')
        return BRIDGE.read_text(encoding='utf-8')

    def test_private_login_and_no_secret_access(self):
        source = self.source()
        for text in ['.nonPersistent()', 'allowsContentJavaScript = true', '.defaultClient',
                     '读取摘要', '返回本次运行', '临时', '取消']:
            self.assertIn(text, source)
        for text in ['CredentialStore', 'httpCookieStore', 'HTTPCookie', 'document.cookie',
                     'WKScriptMessageHandler', 'addScriptMessageHandler', 'URLSession.shared',
                     'SFSafariViewController', 'evaluateJavaScript("document.documentElement']:
            self.assertNotIn(text, source)
        self.assertNotIn('setValue(', source)

    def test_callback_lifecycle_and_native_handoff(self):
        source = self.source()
        for text in ['WorkflowJobSummaryRules.html', 'AccountStore.generation', 'api.isCurrentSession',
                     '.githubAccountChanged', 'navigationID ==', 'web.url ==', 'stopLoading()',
                     'navigationDelegate = nil', 'uiDelegate = nil', 'dismantleUIView',
                     'didFinish', 'targetFrame == nil', 'didReceive challenge', '.cancelAuthenticationChallenge',
                     '!expectedLogin.isEmpty', 'verifiedSummary()', 'summaryNavigationID == navigationID',
                     'private weak var web', 'return container', 'removeFromSuperview()']:
            self.assertIn(text, source)
        self.assertNotIn('ReadmeHTMLView(', source)
        self.assertNotIn('document.documentElement.outerHTML', source)
        self.assertNotIn('document.body', source)

    @unittest.skipUnless(shutil.which('node'), 'node unavailable')
    def test_actual_extraction_script_with_dom_contract_fixture(self):
        source = self.source()
        script = re.search(r'static let extractionScript = #"""\n(.*?)\n    """#', source, re.S).group(1)
        # A deliberately tiny DOM contract fixture; no dependency or network involved.
        program = r'''
const assert = require('assert');
const extract = () => eval(SCRIPT);
let login = 'alice', nodes = [];
global.location = {href: 'https://github.com/o/r/actions/runs/7'};
global.document = {
 querySelector: selector => { assert.equal(selector, 'meta[name="user-login"]'); return login === null ? null : {content: login}; },
 querySelectorAll: selector => { assert.equal(selector, 'job-summary[id]'); return nodes; }
};
function node(id, body, html) { return {id, outerHTML: html, querySelector(selector) {
 assert.equal(selector, '.markdown-body');
 return body === null ? null : {textContent: body, querySelector: () => null};
}}; }
nodes = [node('summary-12', 'Hello', '<job-summary id="summary-12"><div class="markdown-body">Hello</div></job-summary>'),
 node('page', 'Wrong', 'WHOLE PAGE'), node('summary-14', null, 'NO BODY'), node('summary-15', ' ', 'EMPTY')];
let result = extract();
assert.equal(result.login, 'alice'); assert.equal(result.href, location.href);
assert.equal(result.html, nodes[0].outerHTML);
login = null; assert.equal(extract().login, '');
nodes = []; assert.equal(extract().html, '');
nodes = [node('summary-1', 'big', 'x'.repeat(4 * 1024 * 1024 + 1))];
assert.equal(extract().html, '');
console.log('PASS app-owned extraction: identity metadata, only real summary bodies, empty/lazy/oversize rejection');
'''.replace('SCRIPT', json.dumps(script))
        with temporary_folder() as folder:
            path = Path(folder) / 'extract.js'
            path.write_text(program, encoding='utf-8')
            subprocess.run(['node', str(path)], check=True, timeout=20)

    @unittest.skipUnless(shutil.which('swiftc'), 'swiftc unavailable: Foundation rule harness not executed')
    def test_actual_foundation_url_session_result_rules(self):
        source = self.source()
        rules = source.split('// BEGIN FOUNDATION RULES\n')[1].split('// END FOUNDATION RULES')[0]
        parser = ((ROOT / 'RepoPocket/RepositoryInput.swift').read_text()
                  + (ROOT / 'RepoPocket/WorkflowJobSummary.swift').read_text().split('extension GitHub')[0])
        program = 'import Foundation\nstruct AppError: Error { let text: String }\n' + parser + rules + r'''
let expected = URL(string: "https://github.com/o/r/actions/runs/7")!
for text in ["https://github.com/login", "https://github.com:443/login"] {
    precondition(WorkflowSummaryLoginRules.allowed(URL(string: text)))
}
for text in ["http://github.com/login", "https://github.com.evil/login", "https://evil.test", "https://alice@github.com/login", "https://alice:secret@github.com/login", "https://github.com:444/login", "file:///tmp/a"] {
    precondition(!WorkflowSummaryLoginRules.allowed(URL(string: text)))
}
let generation = UUID()
precondition(WorkflowSummaryLoginRules.current(generation, generation, session: true))
precondition(!WorkflowSummaryLoginRules.current(generation, UUID(), session: true))
precondition(!WorkflowSummaryLoginRules.current(generation, generation, session: false))
let fragment = "<job-summary id='summary-1'><div class='markdown-body'>Hello</div></job-summary>"
func result(_ href: String, _ login: String, _ html: String, _ expectedLogin: String = "Alice") -> Bool {
    (try? WorkflowSummaryLoginRules.summary(["href": href, "login": login, "html": html], expectedURL: expected, expectedLogin: expectedLogin)) != nil
}
precondition(result(expected.absoluteString, "alice", fragment))
precondition(!result(expected.absoluteString, "alice", fragment, ""))
precondition(!result(expected.absoluteString, "", fragment, ""))
precondition(!result(expected.absoluteString, "bob", fragment))
precondition(!result(expected.absoluteString + "?x=1", "alice", fragment))
precondition(!result("https://github.com/o/r/actions/runs/8", "alice", fragment))
precondition(!result(expected.absoluteString, "alice", "<html>Not a summary</html>"))
print("PASS URL, account generation, exact run, identity and real parser rules")
'''
        with temporary_folder() as folder:
            path = Path(folder) / 'rules.swift'
            path.write_text(program, encoding='utf-8')
            binary = Path(folder) / 'rules'
            subprocess.run(['swiftc', str(path), '-o', str(binary)], check=True, timeout=120)
            subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
