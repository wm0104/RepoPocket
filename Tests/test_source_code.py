"""Production source language selection and bounded text loading."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('swiftc'), 'Production Swift fixtures execute on macOS')
class SourceCodeTests(unittest.TestCase):
    def test_editor_label_uses_the_selected_grammar_and_text_loading_stays_bounded(self):
        fixture = r'''
import Foundation
@main struct Fixture {
 static func main() throws {
  for (path, text, name, grammar) in [
   ("code.PY", "", "Python", "python"), ("code.swift", "", "Swift", "swift"),
   ("Makefile", "", "Shell", "bash"), (".zshrc", "", "Shell", "bash"),
   ("a.js", "", "JavaScript", "javaScript"), ("a.sql", "", "SQL", "sql"),
   ("a.json", "", "JSON", "json"), ("tool.lua", "", "Lua", "lua"),
   ("Main.cs", "", "C#", "cSharp"), ("module.pyi", "", "Python", "python"),
   ("tool", "#!/usr/bin/env -S python3 -u\r\nprint(1)", "Python", "python"),
   ("tool.lua", "#!/usr/bin/env ruby", "Lua", "lua"),
   ("pkg/DEBIAN/postinst", "", "Shell", "bash")
  ] {
   let language = SourceTextSyntax.language(for: path, text: text)
   precondition(language?.name == name && language?.grammar().rawValue == grammar)
  }
  precondition(SourceTextSyntax.language(for: "note.unknown", text: "def True 123") == nil)
  precondition(SourceTextRules.automaticallyLoads(filename:"code.py",size:353))
  precondition(SourceTextRules.automaticallyLoads(filename:"README.md",size:nil))
  precondition(!SourceTextRules.automaticallyLoads(filename:"picture.png",size:500))
  precondition(!SourceTextRules.automaticallyLoads(filename:"large.py",size:2*1024*1024))
  let decoded = try SourceTextRules.decode(Data("中文\n".utf8));precondition(decoded == "中文\n")
  for bytes in [Data([0,1,2]),Data([0xff,0xfe]),Data(repeating:65,count:1024*1024+1)] {
   do {_ = try SourceTextRules.decode(bytes);preconditionFailure("binary/oversized input accepted")}catch{}
  }
  print("PASS language names, grammar selection and bounded automatic UTF-8 reading")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory)/'Fixture.swift'
            main.write_text(fixture, encoding='utf-8')
            syntax = (ROOT / 'RepoPocket/SourceTextSyntax.swift').read_text(encoding='utf-8')
            # Stand in for the external grammar objects; exercise the app's actual routing on host Swift.
            grammar = """enum TreeSitterLanguage: String {
                case astro, bash, c, cSharp, cpp, css, elixir, elm, go, haskell, html, java, javaScript, json, json5,
                     jsx, julia, latex, lua, markdown, ocaml, perl, php, python, r, ruby, rust, scss, sql, svelte,
                     swift, toml, tsx, typeScript, yaml
            }"""
            router = Path(directory) / 'SourceTextSyntax.swift'
            router.write_text(syntax.replace('import RepoPocketLanguageSupport', grammar), encoding='utf-8')
            output = str(Path(directory)/'test')
            subprocess.run(['swiftc','-parse-as-library',str(ROOT/'RepoPocket/SourceTextRules.swift'),str(router),str(main),'-o',output],check=True)
            subprocess.run([output],check=True,timeout=20)


if __name__ == '__main__':
    unittest.main()
