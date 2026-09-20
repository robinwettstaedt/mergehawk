"""Exercise the release entry point with isolated files and external-command doubles."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
BUILD = '20260920123456'
TAG = 'v0.1.0-' + BUILD
REPO = 'example/downloads'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        (scripts / 'lib').mkdir(parents=True)
        shutil.copy(ROOT / 'scripts/release-github.sh', scripts)
        shutil.copy(ROOT / 'scripts/configure-github-release-secrets.sh', scripts)
        shutil.copy(ROOT / 'scripts/lib/release-env.sh', scripts / 'lib')
        (scripts / 'release-github.env').write_text(
            f'RELEASE_REPOSITORY="{REPO}"\n'
            f'SPARKLE_FEED_URL="https://github.com/{REPO}/releases/latest/download/appcast.xml"\n'
            'SPARKLE_PUBLIC_KEY="test-key"\n')
        self.assets = self.root / '.build/releases' / TAG / 'assets'
        self.assets.mkdir(parents=True)
        self.dmg = self.assets / f'MergeHawk-0.1.0-{BUILD}-apple-silicon.dmg'
        self.dmg.write_bytes(b'installer')
        rss = ET.Element('rss')
        item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
        ET.SubElement(item, NS + 'version').text = BUILD
        ET.SubElement(item, 'enclosure', {
            'url': f'https://github.com/{REPO}/releases/download/{TAG}/{self.dmg.name}',
            'length': str(self.dmg.stat().st_size), NS + 'edSignature': 'test-signature'})
        self.feed = self.assets / 'appcast.xml'
        ET.ElementTree(rss).write(self.feed)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.command('git', '''import sys
if sys.argv[1:] != ['status', '--porcelain']:
    sys.exit('Unexpected git operation')
''')
        self.command('gh', '''import os, sys
args = sys.argv[1:]
if os.environ.get('CHECK_CREDENTIAL_SCOPE'):
    for key in ['DOWNLOADS_TOKEN', 'DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64',
                'DEVELOPER_ID_CERTIFICATE_PASSWORD', 'APPLE_ID', 'APPLE_TEAM_ID',
                'APPLE_APP_SPECIFIC_PASSWORD', 'SPARKLE_PRIVATE_KEY']:
        assert key not in os.environ, 'Unnecessary credential exposed to gh: ' + key
if args[:1] == ['api']:
    if os.environ.get('FAIL_API'):
        sys.exit(1)
    print(os.environ.get('PUBLISHED_TAGS', ''))
elif args[:2] == ['release', 'create'] and os.environ.get('FAIL_CREATE'):
    sys.exit(1)
''')
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        COMMAND_LOG=str(self.root / 'commands.jsonl'),
                        RELEASE_ENV_FILE=str(scripts / 'release-github.env'),
                        RELEASE_LOCAL_ENV_FILE=str(self.root / 'no-local-env'))

    def command(self, name, code):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\n'
                        'import json, os, sys\n'
                        'with open(os.environ["COMMAND_LOG"], "a") as log:\n'
                        '    log.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")\n'
                        + code)
        path.chmod(0o755)

    def run_release(self, *args, phase='--publish-only'):
        return subprocess.run(
            ['bash', str(self.root / 'scripts/release-github.sh'), '--version', 'v0.1.0',
             '--build', BUILD, phase, *args], env=self.env, capture_output=True, text=True)

    def calls(self):
        path = self.root / 'commands.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_uploads_only_public_assets_as_draft_before_publishing_latest(self):
        (self.assets / 'private-debug.log').write_text('must not upload')
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        gh = [call for call in self.calls() if call[0] == 'gh']
        self.assertEqual(gh[0][1:3], ['api', '--paginate'])
        self.assertIn(f'repos/{REPO}/releases', gh[0])
        create, edit = gh[1:]
        self.assertEqual(create[1:4], ['release', 'create', TAG])
        self.assertEqual(edit[1:4], ['release', 'edit', TAG])
        for call in (create, edit):
            self.assertEqual(call[call.index('--repo') + 1], REPO)
            self.assertNotIn('--target', call)
        self.assertIn('--draft', create)
        self.assertIn('--latest=false', create)
        self.assertIn(str(self.dmg), create)
        self.assertIn(str(self.feed), create)
        self.assertFalse(any('private-debug' in arg for arg in create))
        self.assertIn('--draft=false', edit)
        self.assertIn('--latest', edit)
        self.assertEqual([c for c in self.calls() if c[0] == 'git'], [['git', 'status', '--porcelain']])

    def test_requested_draft_never_publishes(self):
        self.assertEqual(self.run_release('--draft').returncode, 0)
        self.assertFalse(any(c[1:3] == ['release', 'edit'] for c in self.calls()))

    def test_failed_upload_does_not_publish(self):
        self.env['FAIL_CREATE'] = '1'
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(any(c[1:3] == ['release', 'edit'] for c in self.calls()))

    def test_remote_query_failure_does_not_create_release(self):
        self.env['FAIL_API'] = '1'
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(any(c[1:2] == ['release'] for c in self.calls()))

    def test_equal_or_newer_existing_build_cannot_be_replaced(self):
        for published in (TAG, 'v0.1.0-20260921123456'):
            with self.subTest(published=published):
                self.env['PUBLISHED_TAGS'] = published
                self.assertNotEqual(self.run_release().returncode, 0)
        self.assertFalse(any(c[1:2] == ['release'] for c in self.calls()))

    def test_older_existing_build_allows_publication(self):
        self.env['PUBLISHED_TAGS'] = 'v0.1.0-20260919123456'
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_feed_is_rejected_before_github(self):
        for field, value in [('url', 'https://example.com/wrong.dmg'), ('length', '100'),
                             (NS + 'edSignature', '')]:
            with self.subTest(field=field):
                original = self.feed.read_bytes()
                tree = ET.parse(self.feed)
                tree.find('./channel/item/enclosure').set(field, value)
                tree.write(self.feed)
                self.assertNotEqual(self.run_release().returncode, 0)
                self.feed.write_bytes(original)
        self.assertFalse(any(c[0] == 'gh' for c in self.calls()))

    def test_invalid_inputs_have_no_external_effects(self):
        for args in [('--version', 'v0.1.0;touch pwned'), ('--build', '1'),
                     ('--build', '20269920123456'), ('--version',)]:
            with self.subTest(args=args):
                self.assertNotEqual(self.run_release(*args).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_setup_credential_file_is_accepted_without_exposing_credentials_to_publish(self):
        local = self.root / 'scripts/release-github.local.env'
        fields = ['DOWNLOADS_TOKEN', 'DEVELOPER_ID_APPLICATION', 'SPARKLE_PRIVATE_KEY',
                  'DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64',
                  'DEVELOPER_ID_CERTIFICATE_PASSWORD', 'APPLE_ID', 'APPLE_TEAM_ID',
                  'APPLE_APP_SPECIFIC_PASSWORD']
        local.write_text('\n'.join(key + '=private-test-value' for key in fields) + '\n')
        self.env['RELEASE_LOCAL_ENV_FILE'] = str(local)
        setup = subprocess.run(
            ['bash', str(self.root / 'scripts/configure-github-release-secrets.sh'), '--dry-run'],
            env=self.env, capture_output=True, text=True)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.env['CHECK_CREDENTIAL_SCOPE'] = '1'
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('private-test-value', result.stdout + result.stderr + setup.stdout + setup.stderr)

    def test_dry_run_does_not_publish(self):
        result = self.run_release('--dry-run', '--allow-dirty')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(REPO, result.stdout)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
