from contextlib import redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


class StyleFailureDiagnosticsTests(unittest.TestCase):
    def report(self, log):
        script = (Path(__file__).resolve().parents[1] / 'Scripts/run_style_preview.sh').read_text(encoding='utf-8')
        code = script.split("<<'PY_FAILED_TESTS'\n", 1)[1].split('\nPY_FAILED_TESTS', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'style-tests.log'
            path.write_text(log, encoding='utf-8')
            output = io.StringIO()
            with patch.object(sys, 'argv', ['-', str(path)]), redirect_stdout(output):
                exec(compile(code, 'run_style_preview.sh diagnostics', 'exec'), {})
            return output.getvalue()

    def test_earlier_failure_keeps_its_full_hierarchy(self):
        failed = "Test Case '-[Suite publicContacts]' started.\nerror: contact not tappable\n"
        failed += ''.join(f'AX row {number}\n' for number in range(250))
        failed += "Test Case '-[Suite publicContacts]' failed (1.0 seconds).\n"
        passed = "Test Case '-[Suite settings]' started.\n" + 'later log\n' * 150
        passed += "Test Case '-[Suite settings]' passed (1.0 seconds).\n"
        self.assertEqual(self.report('runner setup\n' + failed + passed + 'runner summary\n'), failed)

    def test_crashed_active_case_is_not_lost(self):
        active = "Test Case '-[Suite publicContacts]' started.\nerror: runner interrupted\n"
        self.assertEqual(self.report(active), active)


if __name__ == '__main__':
    unittest.main()
