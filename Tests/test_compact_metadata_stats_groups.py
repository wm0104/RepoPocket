from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class CompactMetadataStatisticsTests(unittest.TestCase):
 def test_remote_editor_commit_input_has_no_fixed_empty_form(self):
  text=(ROOT/'RepoPocket/RepoPocketApp.swift').read_text(encoding='utf-8').split('private var editor: some View {',1)[1].split('private func read(',1)[0]
  self.assertNotIn('Form {',text)
  self.assertNotIn('.frame(height: 100)',text)
  self.assertIn('TextField("提交说明", text: $commitMessage)',text)
  self.assertIn('.frame(minHeight: 44)',text)
  self.assertIn('commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty',text)
 def test_deb_editor_related_panels_share_one_native_section(self):
  text=(ROOT/'RepoPocket/DebEditorView.swift').read_text(encoding='utf-8').split('private var editorNavigation:',1)[0]
  self.assertEqual(text.count('Section {'),1)
  self.assertNotIn('Section("',text)
  for token in ['SoftGroupRows(bottom: original.isEmpty && !showsOutput)', 'SoftGroupRows(top: false, bottom: differences.isEmpty && !showsOutput)', 'SoftGroupRows(top: false, bottom: !showsOutput)', 'Text("编辑").font(.subheadline)', 'Text("已生成 · 未替换原文件")']:
   self.assertIn(token,text)
 def test_deb_editor_keeps_validation_and_lifecycle(self):
  text=(ROOT/'RepoPocket/DebEditorView.swift').read_text(encoding='utf-8')
  for token in ['.disabled(busy).transaction { $0.animation = nil; $0.disablesAnimations = true }', 'UIRules.withoutAnimation', 'DebControlEditor.releaseFields', 'onUseForUpload == nil', '.interactiveDismissDisabled(busy)', 'if confirmRemote {']:
   self.assertIn(token,text)
 def test_repository_statistics_use_continuous_unique_rows(self):
  text=(ROOT/'RepoPocket/NativeStatisticsView.swift').read_text(encoding='utf-8').split('struct NativeRepositoryStatisticsView:',1)[1].split('struct NativeActivityChartView:',1)[0]
  self.assertEqual(text.count('Section {'),1)
  self.assertEqual(text.count('SoftGroupRows {'),1)
  for token in ['languages-heading','stars-heading','lines-heading','stars-error','count-error']:
   self.assertIn('SoftGroupRow("'+token+'")',text)
  self.assertIn('SoftGroupRow("language:" + language)',text)
  for token in ['.onDisappear { countTask?.cancel() }', 'guard !counting else { return }', 'try Task.checkCancellation(); guard api.isCurrentSession else { return }', '最多40个 UTF-8 源码文件、每个128 KiB、合计2 MiB']:
   self.assertIn(token,text)
if __name__=='__main__':unittest.main()
