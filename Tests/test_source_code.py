"""Language-specific production lexer and bounded automatic text loading."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc'), 'Production Swift fixtures execute on macOS')
class SourceCodeTests(unittest.TestCase):
    def test_language_tokens_do_not_recolor_comments_or_strings(self):
        fixture = r'''
import Foundation
@main struct Fixture {
 static func main() throws {
  func words(_ source: String, _ filename: String, _ kind: SourceTokenKind) -> [String] {
   SourceLexer.tokens(source, filename: filename).filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
  }
  let py = "# print(100) True\nprint(3.14, True, None, 'return 42')\ndef f():\n    return False"
  precondition(words(py,"code.py",.keyword) == ["True","None","def","return","False"])
  precondition(words(py,"code.py",.builtin) == ["print"])
  precondition(words(py,"code.py",.comment) == ["# print(100) True"])
  precondition(words(py,"code.py",.number) == ["3.14"])
  let triple = "x = \"\"\"hello\n# not a comment\nreturn 4\"\"\"\nprint(x)"
  precondition(words(triple,"code.py",.string).count == 1 && words(triple,"code.py",.comment).isEmpty)
  precondition(words("let x = true // def None", "a.swift", .keyword) == ["let","true"])
  precondition(words("const x = null; # private", "a.js", .keyword) == ["const","null"])
  precondition(words("SELECT name FROM users WHERE id = 12 -- return", "a.sql", .keyword) == ["SELECT","FROM","WHERE"])
  precondition(words("{\"private\":true,\"x\":12}", "a.json", .keyword) == ["true"])
  precondition(SourceLexer.tokens("def True 123", filename:"note.unknown").isEmpty)
  precondition(SourceLanguage.detect("code.PY") == .python)
  precondition(SourceLanguage.detect("code.swift") == .swift)
  precondition(SourceLanguage.detect("Makefile") == .shell)
  precondition(SourceTextRules.automaticallyLoads(filename:"code.py",size:353))
  precondition(SourceTextRules.automaticallyLoads(filename:"README.md",size:nil))
  precondition(!SourceTextRules.automaticallyLoads(filename:"picture.png",size:500))
  precondition(!SourceTextRules.automaticallyLoads(filename:"large.py",size:2*1024*1024))
  let decoded = try SourceTextRules.decode(Data("中文\n".utf8));precondition(decoded == "中文\n")
  for bytes in [Data([0,1,2]),Data([0xff,0xfe]),Data(repeating:65,count:1024*1024+1)] {
   do {_ = try SourceTextRules.decode(bytes);preconditionFailure("binary/oversized input accepted")}catch{}
  }
  print("PASS Python/Swift/JavaScript/SQL/JSON language tokens and bounded automatic UTF-8 reading")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory)/'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            output = str(Path(directory)/'test')
            subprocess.run(['swiftc','-parse-as-library',str(ROOT/'RepoPocket/SourceLexer.swift'),str(main),'-o',output],check=True)
            subprocess.run([output],check=True,timeout=20)


if __name__ == '__main__':
    unittest.main()
