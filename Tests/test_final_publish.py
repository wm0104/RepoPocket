"""Network-free production state fixtures and shared UI/session/performance guards."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class FinalPublishTests(unittest.TestCase):
    def test_native_find_uses_declared_chinese_localization(self):
        project = (ROOT/'project.yml').read_text()
        self.assertIn('developmentLanguage: zh-Hans', project)
        self.assertIn('CFBundleDevelopmentRegion: zh-Hans', project)
        self.assertIn('CFBundleLocalizations: [zh-Hans]', project)
        surface = (ROOT/'RepoPocket/SourceTextSurface.swift').read_text()
        self.assertIn('UIFindInteraction', surface)
        self.assertNotIn('AppleLanguages', surface)
        self.assertNotIn('method_exchangeImplementations', surface)

    def test_shared_form_and_safety(self):
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        entry = (ROOT/'RepoPocket/ReleaseEntryView.swift').read_text()
        picker = (ROOT/'RepoPocket/WorkspaceDocumentPicker.swift').read_text()
        workspace = (ROOT/'RepoPocket/WorkspaceView.swift').read_text()
        upload = (ROOT/'RepoPocket/UploadView.swift').read_text()
        updates = (ROOT/'RepoPocket/UpdateFeature.swift').read_text()
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        for token in ['allowsMultipleSelection: true', 'Task.detached', 'draft.draft = true; draft.marker = .none', 'retainedDraft = created', 'plan.mayFinalize', 'asset.id', 'Int64(asset.size)', 'current.draft', 'try state.check()', '未知同名附件', 'plan.cancel()', 'cleanupAttachments()']:
            self.assertIn(token, ui)
        publish = ui.split('private func publishAttachments',1)[1].split('private func loadMarker',1)[0]
        self.assertLess(publish.index('draft.draft = true'), publish.index('uploadManagedAsset'))
        self.assertLess(publish.index('plan.mayFinalize'), publish.rindex('saveManagedRelease'))
        self.assertNotIn('deleteManaged', publish)
        self.assertIn('ReleaseEntryView(api: api', upload)
        self.assertIn('ReleaseEntryView(api: api', workspace)
        self.assertIn('ReleaseEditorView(api: api', entry)
        self.assertIn('requireWriteAccess(canonical)', entry)
        self.assertIn('generation == AccountStore.generation', entry)
        self.assertIn('showCancel: !request.isZIP', picker)
        self.assertNotIn('let label = UILabel()', picker)
        for token in ['Menu("工作区…")', 'if !selected.isEmpty', 'Text("暂无变更")', '复制实际工作目录路径', '发布为发行版']:
            self.assertIn(token, workspace)
        self.assertIn('await updateChecker.appEntryCheck(api: api)', app)
        self.assertNotIn('.badge(updateChecker.hasUpdate', app)
        self.assertNotIn('Circle().fill(Color.red)', updates)
        self.assertIn('Text("应用更新")', updates)
        for token in ['checker.check(api: api)', 'Button("下载更新")', 'Button("分享 IPA 安装")', 'DisclosureGroup("发布说明"', 'if release.ipaURL != nil']:
            self.assertIn(token, updates)
        self.assertIn('UserDefaults.standard.set(now', updates)
        self.assertIn('!automatic', updates)
        self.assertNotIn('Timer', updates)
        self.assertIn('AppUpdateSessionRules.version', app)
        for path in ROOT.joinpath('RepoPocket').glob('*.swift'):
            text = path.read_text()
            self.assertNotIn('willEnterForegroundNotification', text)
            # External local Git edits need a guarded recheck; other workspaces stay inert.
            self.assertEqual('scenePhase' in text, path.name in ('RepoPocketApp.swift', 'WorkflowViews.swift', 'LocalProjectView.swift'), path.name)
            if path.name == 'LocalProjectView.swift':
                refresh = text.split('private func refreshExternalChanges()', 1)[1].split('private func check(', 1)[0]
                for guard in ('externalRefreshPending', 'visible', 'scenePhase == .active', '!busy', 'sheet == nil', '!pendingCommit', 'syncing == nil', 'valid'):
                    self.assertIn(guard, refresh)
                self.assertIn('await check(force: true)', refresh)
                self.assertNotIn('sync(', refresh)
                self.assertNotIn('configureRemote', refresh)
            if path.name == 'WorkflowViews.swift':
                self.assertEqual(text.count('scenePhase'), 4)
                self.assertIn('@Environment(\\.scenePhase) private var scenePhase', text)
                polling = text.split('.task(id: cancellation.waiting && scenePhase == .active) {', 1)[1].split('        .task {', 1)[0]
                for token in ('guard cancellation.waiting, scenePhase == .active', 'for _ in 0..<60',
                              'Task.sleep(nanoseconds: 5_000_000_000)', 'try Task.checkCancellation()',
                              'guard api.isCurrentSession', 'await refreshRunStatus()', 'cancellation.stopWaiting()'):
                    self.assertIn(token, polling)
                self.assertNotIn('scan()', polling)
                self.assertNotIn('communityMutation(', polling)
        entry = app.split('.onChange(of: scenePhase)', 1)[1].split('.task { await NetworkWarmup', 1)[0]
        self.assertEqual(entry.count('appEntryCheck(api: api)'), 1)
        self.assertNotIn('scan()', entry)
        self.assertIn('private let build: () -> AnyView', ui)

    @unittest.skipUnless(shutil.which('swiftc'), 'production fixtures execute on macOS CI')
    def test_production_phase_retry_cancel_validation_cooldown_version(self):
        source = (ROOT/'RepoPocket/ReleaseManagement.swift').read_text() + (ROOT/'RepoPocket/ReleasePublishPlan.swift').read_text() + (ROOT/'RepoPocket/AppUpdateSessionRules.swift').read_text() + r'''
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
@main struct Run {
 static func main() throws {
  var plan = ReleasePublishPlan()
  plan.begin(); precondition(plan.phase == .creatingDraft)
  plan.created(12); precondition(plan.draftID == 12)
  precondition(!plan.mayFinalize(names: ["a"]))
  plan.acknowledge(name:"a", id:4, size:8)
  precondition(plan.matches(name:"a",id:4,size:8))
  precondition(!plan.matches(name:"a",id:5,size:8))
  precondition(!plan.matches(name:"a",id:4,size:9))
  plan.fail(); plan.begin(); precondition(plan.draftID == 12 && plan.phase == .uploading)
  precondition(plan.mayFinalize(names:["a"]))
  plan.cancel(); precondition(!plan.mayFinalize(names:["a"]))
  plan.begin(); plan.finalizing(); plan.fail(); plan.begin()
  precondition(plan.draftID == 12 && plan.uploaded.count == 1)
  precondition(plan.mayFinalize(names:["a"]))
  plan.finalizing(); plan.finish(); precondition(plan.phase == .complete)
  for size: Int64 in [0,-1,ReleaseManagementRules.assetLimit] { precondition(!ReleaseAttachmentRules.valid(size:size,name:"a",existing:[])) }
  precondition(ReleaseAttachmentRules.valid(size:1,name:"普通文件.dat",existing:[]))
  precondition(!ReleaseAttachmentRules.valid(size:1,name:"a",existing:["a"]))
  precondition(!ReleaseAttachmentRules.valid(size:1,name:"../a",existing:[]))
  let now = Date(timeIntervalSince1970:100_000)
  var cold = AppUpdateSessionRules(); precondition(cold.claim(now:now,last:nil))
  precondition(!cold.claim(now:now.addingTimeInterval(100_000),last:nil))
  var recent = AppUpdateSessionRules(); precondition(!recent.claim(now:now,last:now.addingTimeInterval(-899)))
  var due = AppUpdateSessionRules(); precondition(due.claim(now:now,last:now.addingTimeInterval(-900)))
  var future = AppUpdateSessionRules(); precondition(!future.claim(now:now,last:now.addingTimeInterval(1)))
  precondition(AppUpdateSessionRules.version("1.0.1",build:"5") == "1.0.1")
  print("PASS production phase, fixed draft retry, cancel/finalization failure, identity/size, nonempty/budget/names, session once, 15-minute edge and version format")
 }
}
'''
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'fixture.swift'; p.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(p),'-o',d+'/test'], check=True)
            subprocess.run([d+'/test'], check=True)

if __name__ == '__main__': unittest.main()
