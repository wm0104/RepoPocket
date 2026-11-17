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
