"""Share inbox ownership and paginated social state regressions."""
from pathlib import Path
import shutil, subprocess, sys, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class ShareSocialTests(unittest.TestCase):
    def test_share_extension_is_embedded_and_signed_before_host(self):
        project = (ROOT/'project.yml').read_text()
        self.assertIn('type: app-extension', project)
        self.assertIn('target: RepoPocketShare', project)
        self.assertIn('SharedInbox', project)
        self.assertIn('SWIFT_OBJC_BRIDGING_HEADER: ""', project)
        workflow = (ROOT/'.github/workflows/build.yml').read_text()
        normal = workflow.split('Ad-hoc sign and package IPA')[1].split('Package optional update probe')[0]
        self.assertLess(normal.index('--entitlements ShareExtension/Entitlements.plist'), normal.index('--entitlements Entitlements.plist'))
        self.assertIn('FORK_PEOPLE_ONLY', workflow)
        self.assertIn('fork_people_only:', workflow)

    def test_import_and_picker_lifetimes(self):
        extension = (ROOT/'ShareExtension/ShareViewController.swift').read_text()
        block = extension.split('progress = provider.loadFileRepresentation')[1]
        self.assertLess(block.index('store.importFile'), block.index('continuation.resume()'))
        self.assertNotIn('GitHub', extension)
        self.assertNotIn('Data(contentsOf:', extension)
        inbox = (ROOT/'RepoPocket/ShareInboxView.swift').read_text()
        self.assertIn('guard !attempted', inbox)
        self.assertNotIn('.swipeActions', inbox)
        self.assertIn('ShareInboxStore.live().stage(chosen)', inbox)
        self.assertIn('确认删除', inbox)
        upload = (ROOT/'RepoPocket/UploadView.swift').read_text()
        self.assertIn('ShareInboxView', upload)
        self.assertIn('await select(.success(files))', upload)
        releases = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        self.assertEqual(releases.count('ShareInboxView('), 2)

    def test_social_routes_and_no_appearance_refresh(self):
        source = (ROOT/'RepoPocket/RepositorySocial.swift').read_text()
        self.assertIn('FORK_PEOPLE_ONLY', source)
        self.assertIn('ForkPresentation.peopleOnly', source)
        self.assertIn('UserRepositoriesView(api: api, user:', source)
        self.assertIn('CommitDetailView(api: api, repo: fork.full_name', source)
        self.assertIn('snapshot = (baseSHA, headSHA)', source)
        self.assertIn('guard !commits.attempted', source)
        self.assertNotIn('.onAppear', source)
        self.assertNotIn('.refreshable', source)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native fixtures run on macOS')
    def test_native_inbox_preserves_originals_and_exact_delete(self):
        source = ROOT/'SharedInbox/ShareInboxStore.swift'
        fixture = r'''
import Foundation
@main struct Run {
 static func main() throws {
  let fm = FileManager.default
  let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: home, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: home) }
  let original = home.appendingPathComponent("中文 #U6570.py")
  let bytes = Data([0, 1, 255, 10, 42]); try bytes.write(to: original)
  let store = ShareInboxStore(root: home.appendingPathComponent("inbox"))
  let first = try store.importFile(original)
  let second = try store.importFile(original)
  precondition(first.id != second.id && first.name == "中文 #U6570.py")
  precondition(try Data(contentsOf: store.file(first)) == bytes)
  precondition(try store.items().count == 2)
  let selected = try store.stage([first])
  defer { try? fm.removeItem(at: selected[0].deletingLastPathComponent().deletingLastPathComponent()) }
  try store.remove(first)
  precondition(try store.items().count == 1)
  precondition(try Data(contentsOf: original) == bytes)
  precondition(try Data(contentsOf: selected[0]) == bytes)
  precondition(try Data(contentsOf: store.file(second)) == bytes)
  do { _ = try store.importFile(home); preconditionFailure("directory imported") } catch {}
  do { _ = try store.importFile(original, name: "../escape"); preconditionFailure("path accepted") } catch {}
  do { _ = try store.importFile(original, cancelled: { true }); preconditionFailure("cancel imported") } catch {}
  let link = home.appendingPathComponent("link")
  try fm.createSymbolicLink(at: link, withDestinationURL: original)
  do { _ = try store.importFile(link); preconditionFailure("symlink imported") } catch {}
  precondition(try store.items().count == 1)
  precondition(try fm.contentsOfDirectory(atPath: store.root.path).count == 1)
  print("PASS Unicode, bytes, duplicate names, isolated selection, exact deletion, source retained, directory/path/symlink/cancel rejected")
 }
}
'''
        # Throwing expressions must be evaluated outside nonthrowing autoclosures.
        import re
        count = 0
        lines = []
        for line in fixture.splitlines():
            if 'precondition(try ' in line:
                count += 1
                expr = line.strip()[len('precondition('):-1]
                lines.append(f'  let check{count} = {expr}; precondition(check{count})')
            else: lines.append(line)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path/'Run.swift').write_text('\n'.join(lines))
            subprocess.run(['swiftc', '-parse-as-library', str(source), str(path/'Run.swift'), '-o', str(path/'run')], check=True)
            subprocess.run([str(path/'run')], check=True)

    @unittest.skipUnless(shutil.which('swiftc'), 'Native async fixtures run on macOS')
    def test_native_social_empty_error_and_pagination(self):
        source = (ROOT/'RepoPocket/RepositorySocial.swift').read_text()
        state = '@MainActor final class SocialPageState' + source.split('@MainActor final class SocialPageState',1)[1].split('private struct SocialPageFooter',1)[0]
        fixture = r'''
import Foundation
import Combine
struct RefreshFailure { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
struct Row: Identifiable { let id: Int }
struct Failed: Error {}
@main struct Run {
 @MainActor static func main() async {
  let empty = SocialPageState<Row>(); var calls = 0
  await empty.load(operation: { _ in calls += 1; return [] }, valid: { true })
  precondition(empty.attempted && !empty.more && empty.items.isEmpty)
  for _ in 0..<20 { if !empty.attempted { await empty.load(operation: { _ in calls += 1; return [] }, valid: { true }) } }
  precondition(calls == 1)
  let paged = SocialPageState<Row>(); var pages: [Int] = []
  await paged.load(operation: { p in pages.append(p); return (0..<30).map { Row(id: $0) } }, valid: { true })
  await paged.load(operation: { p in pages.append(p); throw Failed() }, valid: { true })
  precondition(paged.items.count == 30 && !paged.error.isEmpty)
  await paged.retry(operation: { p in pages.append(p); return [Row(id: 29), Row(id: 30)] }, valid: { true })
  precondition(pages == [1,2,2] && paged.items.count == 31 && !paged.more)
  await paged.load(refresh: true, operation: { _ in throw Failed() }, valid: { true })
  precondition(paged.items.count == 31)
  await paged.retry(operation: { p in precondition(p == 1); return [] }, valid: { true })
  precondition(paged.items.isEmpty && !paged.more)
  print("PASS empty initial loads once, failed page retries same page, duplicates removed and refresh failure retains data")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path/'State.swift').write_text('import Foundation\nimport Combine\n'+state)
            (path/'Run.swift').write_text(fixture)
            subprocess.run(['swiftc','-parse-as-library', str(path/'State.swift'),str(path/'Run.swift'),'-o',str(path/'run')],check=True)
            subprocess.run([str(path/'run')],check=True)

if __name__ == '__main__': unittest.main()
