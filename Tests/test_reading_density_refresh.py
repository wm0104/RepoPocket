"""Small modules, native theme selection, and full inline README contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / "RepoPocket" / name).read_text(encoding="utf-8")


class ReadingDensityTests(unittest.TestCase):
    def test_targeted_native_scope_keeps_logs_layout_and_real_screenshots(self):
        workflow = (ROOT / ".github/workflows/ui-check.yml").read_text(encoding="utf-8")
        script = (ROOT / "Scripts/run_style_preview.sh").read_text(encoding="utf-8")
        exporter = (ROOT / "Scripts/export_style_attachments.py").read_text(encoding="utf-8")
        self.assertIn("reading-layout", workflow)
        for token in ["python3 Tests/test_repository_search_routing.py", "python3 Tests/test_workflow_log_presentation.py", "python3 Tests/test_workspace_zip.py"]:
            self.assertIn(token, workflow)
        selected = script.split("  reading-layout)", 1)[1].split(";;", 1)[0]
        for case in ["WorkflowLogTests", "SettingsTests", "RepositoryCollectionsTests",
                     "testSharedGroupCornersSurviveRefreshAndBackNavigation",
                     "testReleaseAttachmentsUseNativeActionsAndInlineDownloadStates"]:
            self.assertIn(case, selected)
        self.assertIn("elif scope == 'reading-layout':", exporter)
        self.assertIn("all) TEST_ARGUMENTS=(-only-testing:RepoPocketStyleUITests)", script)
        self.assertIn("frame.minY + 1", (ROOT / "StyleUITests/StyleBoundaryTests.swift").read_text(encoding="utf-8"))

    def test_shared_cards_use_small_corners_without_clipping_native_rows(self):
        text = source("WorkspaceSelectionUI.swift")
        self.assertIn("let radius: CGFloat = 10", text)
        self.assertIn("cornerRadius: radius, style: .continuous", text)
        self.assertIn("top ? 0 : radius", text)
        self.assertIn("bottom ? 0 : radius", text)
        self.assertEqual(text.count(".clipShape("), 1)
        self.assertIn("radius: CGFloat = 10", source("SheetStyle.swift"))
        self.assertIn("if #available(iOS 16.4, *)", source("SheetStyle.swift"))
        label = source("LocalGitFileLabel.swift")
        self.assertEqual(label.count("cornerRadius: 8, style: .continuous"), 2)
        self.assertIn(".frame(width: 40, height: 44)", label)
        self.assertIn("RoundedRectangle(cornerRadius: 10, style: .continuous)", source("DesktopViews.swift"))
        empty = source("RepoPocketApp.swift").split('Label("此目录没有文件"', 1)[1].split("}", 1)[0]
        self.assertIn(".padding(.vertical, 4)", empty)

    def test_workflow_descriptions_reduce_internal_gaps_without_losing_metrics(self):
        text = source("WorkflowSummaryUI.swift")
        heading = text.split("struct WorkflowRunHeading:", 1)[1].split("struct WorkflowRunMetadata:", 1)[0]
        self.assertIn("spacing: 6", heading)
        metrics = text.split("struct WorkflowRunMetrics:", 1)[1].split("struct WorkflowJobRow:", 1)[0]
        self.assertIn("spacing: 8", metrics)
        self.assertEqual(metrics.count("spacing: 4"), 3)
        for token in ['Text("状态")', 'Text("持续时间")', 'Text("构建产物")', 'WorkflowArtifactsView(api: api']:
            self.assertIn(token, metrics)

    def test_diff_header_and_share_extension_reduce_only_extra_padding(self):
        header = source("LocalDiffPreview.swift").split("Divider()", 1)[0]
        self.assertIn("spacing: 8", header)
        self.assertIn(".padding(.horizontal).padding(.vertical, 8)", header)
        self.assertIn("ContentZoomControls(scale: $scale)", header)
        share = (ROOT / "ShareExtension" / "ShareViewController.swift").read_text(encoding="utf-8")
        self.assertIn("stack.spacing = 12", share)
        self.assertIn("topAnchor, constant: 20", share)
        self.assertIn("save.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)", share)
        self.assertIn("close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)", share)

    def test_home_headers_remove_extra_insets_but_keep_menu_hit_targets(self):
        for name, count in [("RepositoryHomeHighlights.swift", 2), ("RepositoryReadmeSection.swift", 1)]:
            text = source(name)
            self.assertEqual(text.count("EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12)"), count)
            self.assertIn(".frame(width: 44, height: 44)", text)
            self.assertIn("spacingBefore: connected ? 10 : 0", text)
        text = source("RepositoryHomeHighlights.swift")
        for marker, end in [('SoftGroupRow("release-heading")', 'if let release'), ('SoftGroupRow("run-heading")', 'if let run')]:
            header = text.split(marker, 1)[1].split(end, 1)[0]
            self.assertIn("EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12)", header)

    def test_favorite_search_joins_the_existing_group_without_breaking_reorder(self):
        text = source("RepositoryCollectionViews.swift").split("struct RepositoryFavoritesView:")[1].split("struct StarListsView:")[0]
        self.assertIn('ListSearchField(query: $query, title: "收藏夹").softGroupedRow(top: true)', text)
        self.assertIn(".softGroupedRow(top: !searchVisible, bottom: true)", text)
        self.assertIn(".softGroupedRow(top: offset == 0 && !searchVisible, bottom: offset == values.count - 1)", text)
        self.assertIn(".onMove", text)
        self.assertIn("favorites.reorder(order)", text)

    def test_release_attachments_are_compact_without_changing_download_actions(self):
        text = source("ReleaseManagementUI.swift").split("struct ReleaseDetailView:")[1].split("private func assetActions")[0]
        self.assertNotIn("LocalGitFileLabel(name: asset.name", text)
        self.assertIn(".frame(width: 24)", text)
        self.assertIn("Text(asset.name)", text)
        self.assertIn("ByteCountFormatter.string(fromByteCount: Int64(asset.size)", text)
        self.assertIn("minHeight: 44", text)
        self.assertIn("assetActions(asset)", text)
        self.assertIn("ReleaseAssetDownloadStatusView", text)

    def test_module_gap_is_attached_to_the_first_real_row(self):
        text = source("WorkspaceSelectionUI.swift")
        self.assertIn("spacingBefore: CGFloat = 0", text)
        self.assertIn("row.id == rows.first?.id ? spacingBefore : 0", text)
        self.assertIn(".padding(.top, spacingBefore)", text)
        self.assertNotIn("struct SoftGroupGap", text)

    def test_theme_is_a_native_single_selection_submenu_only(self):
        text = source("NativeActionMenu.swift")
        self.assertIn("options: item.singleSelection ? .singleSelection : []", text)
        self.assertIn("singleSelection: Bool = false", text)
        app = source("RepoPocketApp.swift")
        self.assertIn('submenu("主题", symbol: "circle.lefthalf.filled", singleSelection: true', app)
        self.assertIn("current.perform()", text)
        self.assertIn("DispatchQueue.main.async", text)

    def test_sync_actions_are_independent_rows_with_existing_guards(self):
        text = source("LocalProjectView.swift")
        for action in ["fetch", "pull", "push"]:
            self.assertIn(f'SoftGroupRow("sync-{action}")', text)
            self.assertIn(f'syncing = "{action}"', text)
        self.assertNotIn('SoftGroupRow("sync")', text)
        self.assertIn("!state.fresh || snapshot.history.remote.isEmpty", text)

    def test_readme_defaults_to_full_content_and_reuses_the_document(self):
        text = source("RepositoryReadmeSection.swift")
        self.assertIn("api: api, expanded: true", text)
        self.assertNotIn('SoftGroupRow("expand")', text)
        self.assertIn("initialDocument: document", text)
        self.assertIn("initialDocument: ReadmeDocument? = nil", source("ReadingViews.swift"))
        self.assertNotIn("min(max(44", source("ReadmeHTMLView.swift"))

    def test_low_frequency_refreshes_use_menus_but_errors_keep_retry(self):
        for name in ["RepositoryReadmeSection.swift", "RepositoryHomeHighlights.swift"]:
            text = source(name)
            self.assertIn("NativeActionMenu", text)
            self.assertNotIn('SoftGroupRow("refresh")', text)
            self.assertIn('SoftGroupRow("retry")', text)


if __name__ == "__main__":
    unittest.main()
