"""Small modules, native theme selection, and full inline README contracts."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / "RepoPocket" / name).read_text(encoding="utf-8")


class ReadingDensityTests(unittest.TestCase):
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
