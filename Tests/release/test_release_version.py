"""Version selection from published stable release tags and a bump type."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CALCULATOR = ROOT / 'scripts/lib/release-version.py'
REPO = 'example/mergehawk'

# The exact version pipeline the release workflow runs.
PIPELINE = '''set -euo pipefail
source scripts/lib/release-history.sh
tags="$(list_published_release_tags "$GITHUB_REPOSITORY")"
version="$(printf '%s\\n' "$tags" | python3 scripts/lib/release-version.py "$BUMP")"
printf '%s\\n' "$version"
'''


def release(tag, draft=False, prerelease=False):
    return {'tag_name': tag, 'draft': draft, 'prerelease': prerelease}


class ReleaseVersionTests(unittest.TestCase):
    def calculate(self, tags, *bump):
        return subprocess.run(
            [sys.executable, str(CALCULATOR), *bump], input=tags,
            capture_output=True, text=True)

    def assertVersion(self, tags, bump, expected):
        result = self.calculate(tags, bump)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + '\n')

    def test_empty_history_starts_at_one(self):
        for bump in ('patch', 'minor', 'major'):
            with self.subTest(bump=bump):
                self.assertVersion('', bump, '1.0.0')

    def test_bump_types_advance_the_latest_version(self):
        for bump, expected in (('patch', '1.0.1'), ('minor', '1.1.0'), ('major', '2.0.0')):
            with self.subTest(bump=bump):
                self.assertVersion('v1.0.0\n', bump, expected)

    def test_minor_and_major_reset_lower_parts(self):
        self.assertVersion('v1.2.3\n', 'minor', '1.3.0')
        self.assertVersion('v1.2.3\n', 'major', '2.0.0')

    def test_unsorted_tags_use_numeric_maximum(self):
        self.assertVersion('v1.9.0\nv1.10.0\nv1.2.3\n', 'patch', '1.10.1')

    def test_blank_lines_are_ignored(self):
        self.assertVersion('\nv1.0.0\n\n', 'patch', '1.0.1')
        self.assertVersion('\n', 'patch', '1.0.0')

    def test_malformed_tags_are_rejected(self):
        for tag in ('v0.1.18-20261010122536', 'v1.02.0', '1.0.0'):
            with self.subTest(tag=tag):
                result = self.calculate(f'v1.0.0\n{tag}\n', 'patch')
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
                self.assertIn('Unsupported or malformed published release tag: ' + tag, result.stderr)

    def test_missing_or_unknown_bump_is_rejected(self):
        for bump in ((), ('build',), ('patch', 'minor')):
            with self.subTest(bump=bump):
                result = self.calculate('v1.0.0\n', *bump)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, '')
                self.assertIn('Usage: release-version.py <patch|minor|major>', result.stderr)


class ReleaseVersionPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts/lib').mkdir(parents=True)
        for name in ('release-history.sh', 'release-version.py'):
            shutil.copy(ROOT / 'scripts/lib' / name, self.root / 'scripts/lib')
        self.pages = self.root / 'release-pages.json'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(['gh'] + args) + '\\n')
if args[:1] != ['api']:
    sys.exit('Unexpected gh operation')
if os.environ.get('FAIL_API'):
    print('Release history lookup failed', file=sys.stderr)
    sys.exit(1)
pages = json.load(open(os.environ['RELEASE_PAGES_FILE']))
if '--paginate' not in args:
    pages = pages[:1]
expression = args[args.index('--jq') + 1]
for page in pages:
    result = subprocess.run(['/usr/bin/jq', '-r', expression], input=json.dumps(page),
                            text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    if result.returncode:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
''')
        gh.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        COMMAND_LOG=str(self.root / 'commands.jsonl'),
                        RELEASE_PAGES_FILE=str(self.pages),
                        GITHUB_REPOSITORY=REPO, BUMP='patch')

    def resolve(self, pages):
        self.pages.write_text(json.dumps(pages))
        return subprocess.run(['bash', '-c', PIPELINE], cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def calls(self):
        path = self.root / 'commands.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_no_releases_gives_first_version(self):
        for pages in ([], [[]]):
            with self.subTest(pages=pages):
                result = self.resolve(pages)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '1.0.0\n')

    def test_drafts_and_prereleases_are_ignored_across_pages(self):
        result = self.resolve([
            [release('v1.0.0'), release('v1.9.0', draft=True)],
            [release('v1.1.0'), release('v2.0.0', prerelease=True)],
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '1.1.1\n')
        (api,) = self.calls()
        self.assertIn('--paginate', api)
        self.assertIn(f'repos/{REPO}/releases', api)

    def test_failed_history_lookup_gives_no_version(self):
        self.env['FAIL_API'] = '1'
        result = self.resolve([[release('v1.0.0')]])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('Release history lookup failed', result.stderr)


if __name__ == '__main__':
    unittest.main()
