"""Version selection from published stable release tags."""

from pathlib import Path
import subprocess
import sys
import unittest


CALCULATOR = Path(__file__).resolve().parents[2] / 'scripts/lib/release-version.py'


class ReleaseVersionTests(unittest.TestCase):
    def calculate(self, tags):
        return subprocess.run(
            [sys.executable, str(CALCULATOR)], input=tags,
            capture_output=True, text=True)

    def test_repeated_initial_patch_advances_once(self):
        result = self.calculate('v0.1.0-20260901000000\nv0.1.0-20260902000000\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0.1.1\n')

    def test_unsorted_tags_use_numeric_maximum(self):
        result = self.calculate('v0.1.9-20260919000000\nv0.1.2-20260912000000\n'
                                'v0.1.10-20260920000000\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0.1.11\n')

    def test_unchanged_history_returns_same_candidate(self):
        tags = 'v0.1.0-20260901000000\n'
        first = self.calculate(tags)
        second = self.calculate(tags)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, second.stdout)

    def test_missing_or_invalid_history_fails_without_version(self):
        for tags in ('', '\n', 'v0.2.0-20260901000000\n',
                     'v0.1.1-invalid\n', 'v0.1.0-20260901000000\nv1.0.0-20260902000000\n'):
            with self.subTest(tags=tags):
                result = self.calculate(tags)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertTrue(result.stderr.strip())


if __name__ == '__main__':
    unittest.main()
