"""Production pure Swift fixtures run on macOS; static contracts run everywhere."""
from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]

class ReleaseManagementTests(unittest.TestCase):
    def test_root_lazy_navigation_and_bounded_apis(self):
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        added = api.split('// These bounded endpoints',1)[1]
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        app = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text().split('struct BrowserView:',1)[1].split('struct FileView:',1)[0]
        self.assertNotIn('releasePresence', app)
        self.assertIn('if path.isEmpty && !showFiles {', app)
        self.assertEqual(app.count('RepositoryHomeHighlights(api: api, repo: repo,'),1)
        appSource = (ROOT/'RepoPocket/RepoPocketApp.swift').read_text()
        fileView = appSource.split('struct FileView:',1)[1].split('struct SettingsView:',1)[0]
        upload = (ROOT/'RepoPocket/UploadView.swift').read_text()
        for screen in [app, fileView, ui, upload]:
            self.assertNotIn('ShareSheet(url:', screen)
        self.assertIn('downloadNotice = "已下载并保存到 " + DownloadStore.shared.label', app)
        self.assertIn('downloadNotice = "已下载并保存到 " + DownloadStore.shared.label', upload)
        update = (ROOT/'RepoPocket/UpdateFeature.swift').read_text()
        self.assertIn('Button("分享 IPA 安装")', update)
        highlights = (ROOT/'RepoPocket/RepositoryHomeHighlights.swift').read_text()
        self.assertEqual(highlights.count('ReleaseManagementDestination(api: api, repo: repo)'),1)
        load = app.split('private func load() async',1)[1].split('private func deleteRemote',1)[0]
        self.assertNotIn('managedReleases', load)
        self.assertNotIn('managedAssets', load)
        for token in ['Task.detached', 'ensureActiveAccount()', 'Task.checkCancellation()', 'perPage: Int = 20', 'ReleaseAPIRedirectPolicy()', 'current == original', 'permissions?.push', 'ReleaseManagementRules.pageLimit', 'session.upload(for: r, fromFile: file', 'checkedAll', 'ReleaseManagementRules.duplicate']:
            self.assertIn(token,added)
        self.assertNotIn('/git/refs', added)
        self.assertNotIn('upload_url', added)
        self.assertIn('perPage: 1', added)
        self.assertIn('struct Presence: Decodable { let id: Int }', added)
        self.assertIn('if path.isEmpty && !showFiles {', app)
        self.assertIn('api.isCurrentSession', highlights)
        self.assertIn('if path.isEmpty && canWrite', app)
        self.assertIn('暂无发行版', ui)
        self.assertIn('canWrite = false', ui)
        self.assertIn('复制下载链接', ui)
        self.assertIn('UIPasteboard.general.url = link', ui)
        self.assertIn('asset.browser_download_url, repo: state.repo', ui)
        for token in ['private let build: () -> AnyView', 'var body: AnyView { build() }', 'ForEach(state.rows)', 'ForEach(state.assets)', '.onDisappear { state.cancel() }', 'generation == AccountStore.generation', '确认删除这个附件？', '确认删除整个发行版？', '此操作不可恢复。', 'Button("删除", role: .destructive) { performDelete() }', 'target.repo == state.repo', 'target.generation == AccountStore.generation', 'DownloadStore.shared.persist', 'state.notice', 'state.download(asset)', 'DisclosureGroup', 'if expanded', 'original: r', 'RefreshFailure.isCancellation', '新建发行版', '不删除 git 标签', '同名不覆盖', '已公开发行版会立即受到影响']:
            self.assertIn(token,ui)
        self.assertNotIn('AsyncImage',ui)
        transfers=(ROOT/'RepoPocket/ReleaseTransfers.swift').read_text()
        self.assertIn('ReleaseAssetRedirectPolicy()',transfers)
        self.assertIn('completionHandler(nil)',transfers)
        models=(ROOT/'RepoPocket/ReleaseManagement.swift').read_text()
        self.assertNotIn('let assets:',models)
        summary=models.split('struct ReleaseSummary:',1)[1].split('struct ReleaseForm',1)[0]
        self.assertNotIn('let body:',summary)

    def test_inline_branch_and_delete_safety(self):
        picker = (ROOT/'RepoPocket/ReleaseBranchPicker.swift').read_text()
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        for token in ['for page in 1...10', 'batch.count < 30', 'guard complete', 'generation == AccountStore.generation', 'token == identity', 'Task.checkCancellation()', 'task?.cancel()', 'info.permissions?.push', 'state.branches.count > 1', 'LabeledContent("目标分支", value: name)', 'if expanded', 'if searching', 'expanded = false', '.easeInOut(duration: 0.18)', 'accessibilityReduceMotion', '已有 Git 标签不受目标分支影响。', 'value.count == 40', 'api.commitDetail', 'ready = false']:
            self.assertIn(token, picker)
        rows = picker.split('ForEach(visible', 1)[1].split('} else if', 1)[0]
        self.assertNotIn('await', rows)
        self.assertNotIn('.task', rows)
        self.assertIn('guard targetReady, !attachments.isEmpty', ui)
        self.assertIn('attachments.isEmpty || !targetReady', ui)
        self.assertIn('确认删除这个附件？', ui)
        self.assertIn('确认删除整个发行版？', ui)
        self.assertIn('target.generation == AccountStore.generation', ui)
        for text in ['delete', ' DELETE ', '\nDeLeTe\t']:
            self.assertEqual(text.strip().lower(), 'delete')
        for text in ['', 'delet', 'delete now']:
            self.assertNotEqual(text.strip().lower(), 'delete')

    def test_asset_row_actions_are_independent_and_accessible(self):
        import re
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        row = ui.split('ForEach(state.assets) { asset in', 1)[1].split('if state.assets.isEmpty', 1)[0]
        self.assertIn('VStack(alignment: .leading, spacing: 12)', row)
        self.assertEqual(len(re.findall(r'^\s*Button(?:\(| \{)', row, re.M)), 3)
        actions = re.findall(r'Button(?:\(role: \.destructive\))? \{ ([^{}]+) \} label: \{\s*Text\("([^"]+)"\)(.*?)\n\s*\}\s*\.buttonStyle\(\.(borderless|plain)\)', row, re.S)
        self.assertEqual(len(actions), 3, 'Every asset button must explicitly opt out of automatic List activation')
        expected = {
            '下载并保存': 'state.download(asset)',
            '复制下载链接': 'UIPasteboard.general.url = link; copied = true',
            '删除附件': 'prepareDelete(r, asset: asset)',
        }
        self.assertEqual({label: action.strip() for action, label, _, _ in actions}, expected)
        for _, _, label_view, _ in actions:
            self.assertIn('.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)', label_view)
            self.assertIn('.contentShape(Rectangle())', label_view)
            self.assertNotIn('.lineLimit', label_view)
        # The file metadata and every action must be distinct native List rows.
        # An inset Divider inside one VStack caused the measured 1050/1168px mix
        # and omitted separators between metadata/download/copy in the screenshots.
        metadata = row.split('VStack(alignment: .leading, spacing: 12) {', 1)[1].split('}.softGroupedRow(', 1)[0]
        self.assertIn('Text(asset.name)', metadata)
        self.assertIn('asset.size', metadata)
        self.assertNotIn('Button', metadata)
        self.assertNotIn('Divider()', row)
        self.assertEqual(row.count('.softGroupedRow('), 4)
        self.assertIn('}.softGroupedRow(top: asset.id == state.assets.first?.id)', row)
        self.assertIn('let isLastAsset = asset.id == state.assets.last?.id && !state.assetMore', row)
        self.assertIn('.softGroupedRow(bottom: isLastAsset && link == nil && !state.canWrite)', row)
        self.assertIn('.softGroupedRow(bottom: isLastAsset && !state.canWrite)', row)
        self.assertIn('.softGroupedRow(bottom: isLastAsset)', row)
        self.assertIn('if state.canWrite {', row)
        self.assertIn('if let link = link {', row)
        self.assertEqual(row.count('.disabled(state.busy)'), 2)
        self.assertNotIn('.automatic', row)
        self.assertNotIn('.onTapGesture', row)
        self.assertNotIn('HStack', row)  # Stack vertically for iOS 16, small screens and Dynamic Type.

    def test_concise_copy_keeps_safety_and_budget_guards(self):
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        models = (ROOT/'RepoPocket/ReleaseManagement.swift').read_text()
        self.assertNotIn('Latest 无可靠证据', ui)
        self.assertNotIn('每页 20 条，最多', ui)
        self.assertNotIn('新建发行版（默认草稿）', ui)
        self.assertNotIn('附件（独立分页', ui)
        self.assertNotIn('公开附件可直接在浏览器下载', ui)
        self.assertEqual(ui.count('Text("私有附件需在浏览器登录。")'), 1)
        self.assertIn('} footer: {', ui)
        self.assertIn('var draft = false', models)
        self.assertIn('ReleaseManagementRules.more', ui)
        self.assertIn('此操作不可恢复。', ui)
        self.assertIn('已公开发行版会立即受到影响', ui)

    def test_official_marker_and_tag_write_contracts(self):
        ui = (ROOT/'RepoPocket/ReleaseManagementUI.swift').read_text()
        api = (ROOT/'RepoPocket/GitHub.swift').read_text()
        for text in ['Picker("发行版标记"', 'Text("无")', 'Text("预发行版")', 'if !form.draft', 'Text("最新发行版")', 'Toggle("保存为草稿"', 'form.marker = .none', '!markerReady', '发布此发行版？']:
            self.assertIn(text, ui)
        self.assertNotIn('Toggle("预发行"', ui)
        latest = api.split('func managedLatestID(', 1)[1].split('private func verifyManagedTagAvailable', 1)[0]
        for text in ['ensureActiveAccount()', 'Task.checkCancellation()', 'managedLatestCache[canonical]', 'suffix: "/releases/latest"', 'error.status == 404', 'managedRepository(canonical)']:
            self.assertIn(text, latest)
        self.assertNotIn('created_at', latest)
        tag = api.split('private func verifyManagedTagAvailable', 1)[1].split('func invalidateManagedPresence', 1)[0]
        for text in ['"/releases/tags/" + Self.component(tag)', '1...ReleaseManagementRules.pageLimit', '$0.id != originalID', '此标签已有发行版', 'rows.count < ReleaseManagementRules.pageSize']:
            self.assertIn(text, tag)
        self.assertNotIn('/git/refs', tag)
        save = api.split('func saveManagedRelease', 1)[1].split('func deleteManagedRelease', 1)[0]
        for text in ['managedWriteAccess(repo)', 'form.validMarker', 'validTag(form.tag)', 'current == original', '"make_latest": form.makeLatest', 'object.removeValue(forKey: "make_latest")']:
            self.assertIn(text, save)
        self.assertNotIn('form.title ==', save)
        upload = api.split('func uploadManagedAsset', 1)[1]
        for text in ['1...ReleaseManagementRules.pageLimit', 'duplicate(name: file.lastPathComponent', 'guard checkedAll']:
            self.assertIn(text, upload)

    def test_commit_patch_scope_and_ui(self):
        view=(ROOT/'RepoPocket/CommitPatchView.swift').read_text()
        desktop=(ROOT/'RepoPocket/DesktopViews.swift').read_text()
        self.assertIn('CommitPatchDestination(file: f)',desktop)
        self.assertNotIn('Text(f.preview)',desktop)
        for token in ['LazyVStack(alignment: .leading', '.topLeading', 'row.old', 'row.new', 'row.marker', 'Color.green.opacity(0.12)', 'Color.red.opacity(0.12)', 'whitespace = true', '原始 patch', '仅显示本次提交的变化', 'if result.limited', '不代表没有改动', 'Task.detached', 'withTaskCancellationHandler', 'worker.cancel()', 'try Task.checkCancellation()']:
            self.assertIn(token,view)
        self.assertNotIn('api.',view)
        self.assertNotIn('before',view)
        self.assertNotIn('after',view)

    @unittest.skipUnless(shutil.which('swiftc'), 'production Swift executes in macOS CI; no local Swift compiler')
    def test_production_models_parser_budget_and_cancellation(self):
        source=(ROOT/'RepoPocket/ReleaseManagement.swift').read_text()+(ROOT/'RepoPocket/CommitPatch.swift').read_text()+r'''
struct AppError: LocalizedError { let text: String; var errorDescription: String? { text } }
struct Item: Identifiable { let id: Int }
@main struct Run {
 static func main() async throws {
  precondition(!ReleaseManagementRules.canWrite(nil, session:true))
  precondition(!ReleaseManagementRules.canWrite(false, session:true))
  precondition(!ReleaseManagementRules.canWrite(true, session:false))
  precondition(ReleaseManagementRules.canWrite(true, session:true))
  precondition(!ReleaseManagementRules.validPage(0) && !ReleaseManagementRules.validPage(51))
  precondition(ReleaseManagementRules.more(count:20,page:1))
  precondition(!ReleaseManagementRules.more(count:19,page:1) && !ReleaseManagementRules.more(count:20,page:50))
  let merged=ReleaseManagementRules.merged([Item(id:1)], [Item(id:1),Item(id:2),Item(id:2)])
  precondition(merged.map(\.id) == [1,2])
  let large = (0..<10_000).map { Item(id:$0) }
  let deduped = ReleaseManagementRules.merged(large, large)
  precondition(deduped.count == 10_000)
  do { _ = try JSONDecoder().decode(ReleaseSummary.self,from:Data("{broken".utf8)); preconditionFailure("invalid JSON accepted") } catch {}
  precondition(!ReleaseManagementRules.validAsset(size:ReleaseManagementRules.assetLimit,name:"a"))
  precondition(ReleaseManagementRules.validAsset(size:ReleaseManagementRules.assetLimit-1,name:"中文😀.zip"))
  for name in ["", "..", ".", "a/b", "a\\b", "a\nb"] { precondition(!ReleaseManagementRules.validAsset(size:1,name:name)) }
  precondition(ReleaseManagementRules.duplicate(name:"test.zip",names:["test.zip"]))
  precondition(!ReleaseManagementRules.duplicate(name:"new.zip",names:["test.zip"]))
  let link="https://github.com/o/r/releases/download/v1/test.zip"
  precondition(ReleaseManagementRules.browserDownloadURL(link,repo:"o/r") != nil)
  for bad in ["https://evil.com/o/r/releases/download/v1/a", "https://api.github.com/repos/o/r/releases/assets/1", "https://github.com/x/r/releases/download/v1/a", link+"?token=secret", "http://github.com/o/r/releases/download/v1/a", "https://token@github.com/o/r/releases/download/v1/a", link+"#fragment"] { precondition(ReleaseManagementRules.browserDownloadURL(bad,repo:"o/r") == nil) }
  let huge=String(repeating:"中文😀", count:20_000)
  precondition(!ReleaseManagementRules.editable(huge))
  precondition(ReleaseManagementRules.displayBody(huge).count == ReleaseManagementRules.displayBodyLimit)
  let json = #"{"id":7,"tag_name":"v1","name":"Title","draft":true,"prerelease":false,"created_at":"2026-10-13","updated_at":"now","body":"完整正文","assets":[{"unknown":"ignored"}]}"#
  let summary = try JSONDecoder().decode(ReleaseSummary.self, from: Data(json.utf8))
  let detail = try JSONDecoder().decode(ManagedRelease.self, from: Data(json.utf8))
  precondition(summary.id==7 && detail.body=="完整正文" && detail.draft)
  precondition(ReleaseForm(detail).body==detail.body)
  var form = ReleaseForm()
  precondition(!form.draft && form.marker == .none && form.makeLatest == "false" && !form.prerelease)
  form.marker = .prerelease
  precondition(form.prerelease && form.makeLatest == "false" && form.validMarker)
  form.marker = .latest
  precondition(!form.prerelease && form.makeLatest == "true" && form.validMarker)
  form.draft = true; precondition(!form.validMarker)
  let publishedJSON = json.replacingOccurrences(of: "\"draft\":true", with: "\"draft\":false")
  let published = try JSONDecoder().decode(ManagedRelease.self, from: Data(publishedJSON.utf8))
  precondition(ReleaseForm(published, latestID:7).marker == .latest)
  precondition(ReleaseForm(published, latestID:8).marker == .none)
  precondition(ReleaseForm(detail, latestID:7).draft && ReleaseForm(detail, latestID:7).marker != .latest)
  for tag in ["v1.0.0+2", "版本/测试😀", "release/v1", "1.0.0"] { precondition(ReleaseManagementRules.validTag(tag)) }
  for tag in ["", "@", "a b", "a\nb", "a\u{7f}", "a~", "a^", "a:", "a?", "a*", "a[", "a\\b", "a..b", "a@{b", "a//b", "a/", "/a", "a.", ".a", "a/.b", "a.lock", "a.lock/b"] { precondition(!ReleaseManagementRules.validTag(tag)) }
  let duplicateJSON = #"{"errors":[{"field":"tag_name","code":"already_exists"}]}"#
  precondition(ReleaseManagementRules.tagAlreadyExists(Data(duplicateJSON.utf8)))
  precondition(!ReleaseManagementRules.tagAlreadyExists(Data("{broken".utf8)))
  precondition(!ReleaseManagementRules.tagAlreadyExists(Data(#"{"errors":[{"field":"name","code":"already_exists"}]}"#.utf8)))
  let payload = try JSONSerialization.data(withJSONObject:["make_latest":form.makeLatest,"prerelease":form.prerelease])
  let decodedPayload = try JSONSerialization.jsonObject(with:payload) as! [String:Any]
  precondition(decodedPayload["make_latest"] as? String == "true" && decodedPayload["prerelease"] as? Bool == false)
  let patch = "@@ -10,2 +20,2 @@ func\n-old😀\n+新中文\n context\n\\ No newline at end of file"
  let parsed=try CommitPatchParser.parse(patch)
  precondition(parsed.rows.count==5 && !parsed.malformed)
  precondition(parsed.rows[1].old==10 && parsed.rows[1].new==nil)
  precondition(parsed.rows[2].old==nil && parsed.rows[2].new==20)
  precondition(parsed.rows[3].old==11 && parsed.rows[3].new==21)
  precondition(parsed.rows[4].text=="文件末尾没有换行")
  precondition(parsed.rows[0].text.contains("区块") && !parsed.rows[0].text.contains("@@"))
  let insertion=try CommitPatchParser.parse("@@ -0,0 +1,1 @@\n+你好😀")
  precondition(insertion.rows[1].new==1 && !insertion.malformed)
  let malformed=try CommitPatchParser.parse("@@ broken\n+something")
  precondition(malformed.malformed && malformed.rows[1].old==nil)
  let incomplete=try CommitPatchParser.parse("@@ -1,2 +1,2 @@\n context")
  precondition(incomplete.malformed)
  let enormous=try CommitPatchParser.parse("@@ -0,0 +1,1 @@\n+"+String(repeating:"😀",count:300_000))
  precondition(enormous.limited && enormous.rows.count<=CommitPatchParser.rowLimit)
  precondition(enormous.rows[1].text.count<=CommitPatchParser.lineLimit)
  precondition(CommitPatchParser.visible("a b\tc",whitespace:true).contains("·"))
  precondition(CommitPatchParser.visible("a b\tc",whitespace:false)=="a b\tc")
  let t=Task { try await Task.sleep(nanoseconds: 5_000_000_000); return try CommitPatchParser.parse(patch) }
  t.cancel()
  do { _ = try await t.value; preconditionFailure("cancel must not succeed") } catch is CancellationError {} catch { preconditionFailure("wrong cancellation") }
  print("PASS production release budgets, permissions, page dedup, duplicate naming, full body and commit patch numbering/unicode/malformed/budget/cancellation")
 }
}
'''
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'main.swift'; p.write_text(source)
            subprocess.run(['swiftc','-parse-as-library',str(p),'-o',d+'/tests'],check=True)
            subprocess.run([d+'/tests'],check=True)

if __name__=='__main__': unittest.main()
