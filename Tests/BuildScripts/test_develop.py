"""The concise command must report real tests and preserve failing exit status."""

import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import develop


class DevelopOutputTests(unittest.TestCase):
    def test_summary_combines_xctest_targets_and_excludes_skipped_tests(self):
        output = ("Test Suite 'All tests' passed at a synthetic time.\n"
                  "\t Executed 12 tests, with 2 tests skipped and 0 failures (0 unexpected)\n"
                  "Test Suite 'All tests' passed at a synthetic time.\n"
                  "\t Executed 3 tests, with 0 failures (0 unexpected)\n")
        self.assertEqual(develop.test_summary("Ran 4 tests in 0.01s\nOK\n", output),
                         "Tests passed: 4 release-script tests, 13 app tests (2 skipped).")

    def test_missing_empty_or_failed_results_cannot_be_reported_as_passing(self):
        for output in ("", "Test run with 0 tests passed.",
                       "Test Suite 'All tests' passed.\n Executed 0 tests, with 0 failures\n",
                       "Test Suite 'All tests' passed.\n Executed 3 tests, with 1 failure\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                develop.test_summary("Ran 4 tests in 0.01s\nOK\n", output)

    def test_failure_preserves_diagnostics_log_and_nonzero_status(self):
        Path("/tmp/MajorTom").mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir="/tmp/MajorTom") as log, \
             contextlib.redirect_stdout(io.StringIO()) as stdout, \
             contextlib.redirect_stderr(io.StringIO()) as stderr:
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                develop.run_stage("Synthetic test", [sys.executable, "-c",
                    "import sys; print('ordinary detail'); print('error: synthetic failure'); sys.exit(7)"], log)
            self.assertEqual(failure.exception.returncode, 7)
            self.assertIn("error: synthetic failure", stderr.getvalue())
            self.assertNotIn("ordinary detail", stdout.getvalue())
            self.assertIn("ordinary detail", Path(log.name).read_text())


if __name__ == "__main__":
    unittest.main()
