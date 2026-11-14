from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ZIPFilenameEncodingTests(unittest.TestCase):
    def test_workspace_import_decodes_github_archive_paths_as_utf8(self):
        source = (ROOT / "RepoPocket/WorkspaceZIP.swift").read_text(encoding="utf-8")
        self.assertIn("Archive(url: source, accessMode: .read, pathEncoding: .utf8)", source)


if __name__ == "__main__":
    unittest.main()
