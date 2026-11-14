"""Production diff model tests; Swift execution is mandatory on macOS CI."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class LocalDiffTests(unittest.TestCase):
    def test_preview_contract(self):
        ui = (ROOT/'RepoPocket/LocalDiffPreview.swift').read_text()
        model = (ROOT/'RepoPocket/LocalDiffModel.swift').read_text()
        for token in ['Task.detached', 'withTaskCancellationHandler', 'worker.cancel()', '@State private var whitespace = true', 'LazyVStack', 'textSelection', '仅空白变化', '无末尾换行']:
            self.assertIn(token, ui)
        self.assertNotIn('write(', ui + model)
        self.assertIn('1_000_000', model)
        self.assertIn('200_000', model)
        self.assertIn('Task.checkCancellation()', model)
        self.assertNotIn('String(data:', model)

    @unittest.skipUnless(shutil.which('swiftc'), 'No Swift compiler on Linux device; executed by macOS CI')
    def test_production_model(self):
        harness = r'''
import Foundation
@main struct Harness {
 static func main() async throws {
 func check(_ a: String, _ b: String) throws -> LocalDiffModel.Result {
  let r = try LocalDiffModel.compute(before: a, after: b)
  precondition(r.rows.filter { $0.kind != .addition }.map { $0.raw }.joined() == a)
  precondition(r.rows.filter { $0.kind != .deletion }.map { $0.raw }.joined() == b)
  for row in r.rows { precondition(row.runs.map { $0.text }.joined() == row.raw) }
  return r
 }
 let empty = try check("", ""); precondition(empty.rows.isEmpty)
 let add = try check("", "a\n"); precondition(add.additions == 1 && add.deletions == 0)
 let del = try check("a\n", ""); precondition(del.deletions == 1)
 let one = try check("abc\n", "axc\n")
 precondition(one.rows[0].runs.filter { $0.emphasized }.map { $0.text }.joined() == "b")
 precondition(one.rows[1].runs.filter { $0.emphasized }.map { $0.text }.joined() == "x")
 for pair in [("a b\n", "a  b\n"), ("a\tb\n", "a b\n"), ("a\n", "a\n\n"), ("a", "a\n"), ("\n", ""), ("a\r\n", "a\n")] {
  let r = try check(pair.0, pair.1); precondition(r.whitespaceOnly && r.additions + r.deletions > 0)
 }
 precondition(LocalDiffModel.lines("\n\n") == ["\n", "\n"])
 precondition(LocalDiffModel.visible(" \t\r\n", whitespace: true) == "·⇥␍↵")
 precondition(LocalDiffModel.visible("a \t\n", whitespace: false) == "a \t")
 let unicode = try check("中文👨‍👩‍👧‍👦好\n", "中文🙂好\n")
 precondition(unicode.rows[0].runs.filter { $0.emphasized }.map { $0.text }.joined() == "👨‍👩‍👧‍👦")
 let context = (0..<20).map { "line\($0)\n" }.joined()
 let folded = try check(context, context.replacingOccurrences(of: "line10\n", with: "edited\n"))
 precondition(folded.entries.contains { if case .gap = $0 { return true }; return false })
 precondition(folded.changes.count == 1)
 let big = try check(String(repeating: "a\n", count: 16000), String(repeating: "b\n", count: 16000))
 precondition(big.degraded && big.deletions == 16000 && big.additions == 16000)
 let long = try check(String(repeating: "a", count: 64000), String(repeating: "b", count: 64000))
 precondition(long.additions == 1 && long.deletions == 1)
 for a in ["", "x", "x\n", "\n", "x\ny\n", " y\t\r\n", "中文🙂"] {
  for b in ["", "y", "y\n", "\n", "y\nx\n", "中文🙂"] { _ = try check(a,b) }
 }
 actor Gate {
  var opened = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
   if opened { return }
   await withCheckedContinuation { continuation = $0 }
  }
  func release() { opened = true; continuation?.resume(); continuation = nil }
 }
 let gate = Gate()
 let worker = Task.detached {
  await gate.wait()
  // Cancellation is established before entering production compute, not raced
  // against completion of a small input on a fast runner.
  return try LocalDiffModel.compute(before: context, after: "x")
 }
 worker.cancel()
 await gate.release()
 do { _ = try await worker.value; fatalError("Cancellation not honored") } catch is CancellationError { }
 print("PASS production diff reconstruction, insertion/deletion, inline, whitespace, newline, Unicode, context, budget and cancellation")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)/'Harness.swift'; p.write_text(harness)
            binary = str(Path(directory)/'tests')
            subprocess.run(['swiftc', '-parse-as-library', str(ROOT/'RepoPocket/LocalDiffModel.swift'), str(p), '-o', binary], check=True)
            subprocess.run([binary], check=True)

if __name__ == '__main__': unittest.main()
