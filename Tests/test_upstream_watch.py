"""Home upstream updates use account-local baselines, never mutate a repository."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class UpstreamWatchTests(unittest.TestCase):
    def test_home_entry_and_no_implicit_repository_writes(self):
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        self.assertIn('UpstreamUpdatesSection(api: api)', app)
        path = ROOT/'RepoPocket/UpstreamUpdates.swift'
        self.assertTrue(path.exists())
        source = path.read_text()
        self.assertIn('LocalGitBranchPicker', source)
        self.assertIn('UpstreamSyncView', source)
        self.assertIn('CommitDetailView', source)
        self.assertIn('RepoPocket.upstreamForegroundCheck', source)
        self.assertIn('RepoPocket.upstreamForegroundCheck', app)
        self.assertNotIn('scenePhase', source)
        for operation in ('mergeUpstream(', 'applyUpstreamFastForward(', 'createUpstreamRef('):
            self.assertNotIn(operation, source)

    def test_sync_reuses_declared_target_and_invalidates_suggested_source(self):
        feature = (ROOT/'RepoPocket/UpstreamSync.swift').read_text()
        self.assertIn('var initialUpstream: UpstreamSyncRules.Target? = nil', feature)
        self.assertNotIn('TextField("上游分支"', feature)
        hint = feature.split('for hint in hints', 1)[1].split('} label:', 1)[0]
        self.assertIn('state.upstreamBranch = hint.branch ?? ""', hint)
        self.assertIn('state.compare = nil', hint)

    def test_repository_input_invalidates_branch_in_one_update(self):
        feature = (ROOT/'RepoPocket/UpstreamUpdates.swift').read_text()
        form = feature.split('private struct UpstreamWatchAddView: View {', 1)[1].split('private struct UpstreamUpdatesDetail:', 1)[0]
        self.assertIn('text: Binding(get: { repository }, set:', form)
        self.assertNotIn('.onChange(of: repository)', form)
        self.assertIn('repository = $0; branch = ""', form)
        self.assertEqual(form.count('RepositoryInput.parse(repository)'), 1)
        self.assertNotIn('NavigationLink {', form)
        self.assertIn('.sheet(isPresented:', form)
        self.assertIn('repo: selectedRepository', form)
        self.assertNotIn('.task', form)
        self.assertNotIn('api.branches(', form)
        self.assertIn('upstream-watch-repository', form)
        self.assertIn('upstream-watch-close', form)

    def test_preview_keeps_its_route_and_initializes_source_once(self):
        feature = (ROOT/'RepoPocket/UpstreamSync.swift').read_text()
        view = feature.split('struct UpstreamSyncView: View {', 1)[1]
        self.assertIn('guard !initialized else { return }', view)
        self.assertIn('initialized = true', view)
        source = view.split('@ViewBuilder private var sourceSection:', 1)[1].split('@ViewBuilder private var previewSection:', 1)[0]
        self.assertNotIn('NavigationLink {', source)
        self.assertIn('branchRepository =', source)
        self.assertIn('.sheet(isPresented:', view)
        self.assertIn('upstream-preview-error', view)
        self.assertIn('upstream-preview-loading', view)
        self.assertIn('UpstreamSyncRules.initialSource(', feature)
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        self.assertTrue('Button("上游同步") { showingUpstreamSync = true }' in app)
        self.assertTrue('.navigationDestination(isPresented: $showingUpstreamSync)' in app)
        self.assertFalse('NavigationLink { UpstreamSyncView(' in app)
        self.assertIn('repository?.fork != false', view)
        self.assertIn('$0.default_branch ?? ""', view)
        self.assertNotIn('branches.first', view)

    def test_upstream_ui_regressions_exercise_shipping_navigation(self):
        ui = (ROOT/'StyleUITests/StyleBoundaryTests.swift').read_text()
        for name in ('testUpstreamWatchLinkInputKeepsFormResponsiveAndBranchSelectionExplicit',
                     'testUpstreamPreviewResolvesForkParentAndStaysOnResult',
                     'testUpstreamPreviewFailureStaysOnFormWithError'):
            self.assertTrue('func ' + name + '()' in ui, name)
        preview = (ROOT/'RepoPocket/UserConnectionsStylePreview.swift').read_text()
        self.assertIn('BrowserView(api: api, repo: "fixture-owner/sample", path: "", branch: "main")', preview)
        self.assertIn('/compare/main...fixture-upstream:develop', preview)

    @unittest.skipUnless(shutil.which('swiftc'), 'Production rules run on macOS')
    def test_baseline_and_unread_updates_use_source_sha(self):
        feature = (ROOT/'RepoPocket/UpstreamSync.swift').read_text().split('@MainActor final class UpstreamSyncState',1)[0].replace('import SwiftUI','import Foundation',1)
        source = feature + '\n' + (ROOT/'RepoPocket/RepositoryInput.swift').read_text() + '\n' + (ROOT/'RepoPocket/DesktopModels.swift').read_text() + '\n' + (ROOT/'RepoPocket/UpstreamWatchRules.swift').read_text()
        source += r'''
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
@main struct Test {
 static func main() throws {
  let parent = UpstreamSyncRules.Target(repository:"direct/parent", branch:"develop")
  let root = UpstreamSyncRules.Target(repository:"network/root", branch:"main")
  let saved = UpstreamSyncRules.encodeMemory(repository:"chosen/upstream", branch:"release")
  let remembered = UpstreamSyncRules.initialSource(saved:saved, fork:true, parent:parent, source:root, current:"mine/fork")
  precondition(remembered?.repository == "chosen/upstream" && remembered?.branch == "release")
  let direct = UpstreamSyncRules.initialSource(saved:nil, fork:true, parent:parent, source:root, current:"mine/fork")
  precondition(direct == parent)
  precondition(UpstreamSyncRules.initialSource(saved:nil, fork:true, parent:nil, source:root, current:"mine/fork") == root)
  precondition(UpstreamSyncRules.initialSource(saved:nil, fork:false, parent:parent, source:root, current:"mine/fork") == nil)
  precondition(UpstreamSyncRules.initialSource(saved:nil, fork:true, parent:parent, source:root, current:"DIRECT/parent") == root)
  let invalid = UpstreamSyncRules.Target(repository:"bad/url/extra", branch:"main")
  precondition(UpstreamSyncRules.initialSource(saved:nil, fork:true, parent:invalid, source:root, current:"mine/fork") == root)
  precondition(UpstreamSyncRules.initialSource(saved:"invalid", fork:true, parent:parent, source:root, current:"mine/fork") == parent)
  let unknownBranch = UpstreamSyncRules.Target(repository:"direct/parent", branch:"")
  precondition(UpstreamSyncRules.initialSource(saved:nil, fork:true, parent:unknownBranch, source:root, current:"mine/fork")?.branch == "")
  let source = try UpstreamWatchRules.watch(repository: "https://github.com/team/project", branch: "feature/topic")
  precondition(source.repository == "team/project" && source.branch == "feature/topic")
  precondition(UpstreamWatchRules.newBranches(seen:nil,current:["main","feature/topic"]).isEmpty)
  let ack = UpstreamWatchRules.acknowledge(source, head:String(repeating:"a",count:40), branches:["main","feature/topic"])
  let same = try UpstreamWatchRules.comparePath(ack, head:String(repeating:"a",count:40))
  precondition(same == nil)
  let changed = try UpstreamWatchRules.comparePath(ack, head:String(repeating:"b",count:40))
  precondition(changed == "/repos/team/project/compare/" + String(repeating:"a",count:40) + "..." + String(repeating:"b",count:40))
  precondition(UpstreamWatchRules.newBranches(seen:ack.seenBranches,current:["main","feature/topic","fix/new"]) == ["fix/new"])
  precondition(UpstreamWatchRules.key("account-a") != UpstreamWatchRules.key("account-b"))
  let bytes = try JSONEncoder().encode(ack)
  let restored = try JSONDecoder().decode(UpstreamWatch.self, from:bytes)
  precondition(restored == ack)
  do { _ = try UpstreamWatchRules.watch(repository:"team/project",branch:"../escape"); preconditionFailure("invalid branch accepted") } catch {}
  print("PASS upstream update baseline, branch choice, unread changes and account isolation")
 }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp)/'Watch.swift'; file.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(file),'-o',tmp+'/watch'],check=True)
            subprocess.run([tmp+'/watch'],check=True)

if __name__ == '__main__': unittest.main()
