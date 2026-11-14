from pathlib import Path
import shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]

class LocalFilePresentationTests(unittest.TestCase):
    def test_editor_is_scoped_to_frozen_request(self):
        source = (ROOT/'RepoPocket/LocalProjectEditor.swift').read_text(encoding='utf-8')
        self.assertIn('.id(file.id)', source)
        self.assertIn('filePresentation.didDismiss()', source)
        self.assertNotIn('opened = LocalProjectFile', source)
        self.assertIn('fingerprint = ""',source.split('private func open() async',1)[1])

    @unittest.skipUnless(shutil.which('swiftc'), 'Native presentation state runs on macOS')
    def test_production_presentation_state(self):
        fixture = '''import Foundation
@main struct Run {
 static func main() {
  var state = LocalFilePresentation()
  state.open(path: "one.py")
  let first = state.selected!.id
  for _ in 0..<100 { state.open(path: "two.py", deleting: true) }
  precondition(state.locked && state.selected?.id == first && state.selected?.path == "one.py" && state.selected?.deleting == false)
  state.dismissing()
  precondition(state.locked && state.selected == nil)
  state.open(path: "two.py")
  precondition(state.selected == nil, "Dismissal animation must not accept a replacement")
  state.didDismiss()
  state.open(path: "one.py", deleting: true)
  precondition(state.selected?.id != first && state.selected?.deleting == true)
  state.dismissing(); state.didDismiss()
  state.open(path: "one.py")
  precondition(state.selected?.deleting == false)
  print("PASS production file presentation: duplicate taps, dismissal gate, fresh identity and deletion isolation")
 }
}'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.swift'; path.write_text(fixture, encoding='utf-8')
            subprocess.run(['swiftc','-parse-as-library',str(ROOT/'RepoPocket/LocalFilePresentation.swift'),str(path),'-o',folder+'/test'],check=True)
            subprocess.run([folder+'/test'],check=True)

if __name__ == '__main__': unittest.main()
