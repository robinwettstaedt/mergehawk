"""Exercise the release entry point with isolated files and external-command doubles."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
BUILD = '20260920123456'
VERSION = '0.1.1'
TAG = 'v' + VERSION + '-' + BUILD
REPO = 'example/downloads'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
BASELINE = 'v0.1.0-20260919123456'


def release(tag, draft=False, prerelease=False):
    return {'tag_name': tag, 'draft': draft, 'prerelease': prerelease}


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
        shutil.copy(ROOT / 'scripts/lib/release-history.sh', scripts / 'lib')
        shutil.copy(ROOT / 'scripts/lib/release-version.py', scripts / 'lib')
        (scripts / 'release-github.env').write_text(
            f'RELEASE_REPOSITORY="{REPO}"\n'
            f'SPARKLE_FEED_URL="https://github.com/{REPO}/releases/latest/download/appcast.xml"\n'
            'SPARKLE_PUBLIC_KEY="test-key"\n')
        self.assets = self.root / '.build/releases' / TAG / 'assets'
        self.assets.mkdir(parents=True)
        self.dmg = self.assets / f'MergeHawk-{VERSION}-{BUILD}-apple-silicon.dmg'
        self.dmg.write_bytes(b'installer')
        rss = ET.Element('rss')
        item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
        ET.SubElement(item, NS + 'version').text = BUILD
        ET.SubElement(item, NS + 'shortVersionString').text = VERSION
        ET.SubElement(item, 'enclosure', {
            'url': f'https://github.com/{REPO}/releases/download/{TAG}/{self.dmg.name}',
            'length': str(self.dmg.stat().st_size), NS + 'edSignature': 'test-signature'})
        self.feed = self.assets / 'appcast.xml'
        ET.ElementTree(rss).write(self.feed)
        self.pages = self.root / 'release-pages.json'
        self.set_pages([[release(BASELINE)]])
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.command('git', '''import sys
if sys.argv[1:] != ['status', '--porcelain']:
    sys.exit('Unexpected git operation')
''')
        self.command('gh', '''import json, os, subprocess, sys
args = sys.argv[1:]
if os.environ.get('CHECK_CREDENTIAL_SCOPE'):
    for key in ['DOWNLOADS_TOKEN', 'DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64',
                'DEVELOPER_ID_CERTIFICATE_PASSWORD', 'APPLE_ID', 'APPLE_TEAM_ID',
                'APPLE_APP_SPECIFIC_PASSWORD', 'SPARKLE_PRIVATE_KEY']:
        assert key not in os.environ, 'Unnecessary credential exposed to gh: ' + key
if args[:2] == ['auth', 'status']:
    if os.environ.get('FAIL_AUTH'):
        sys.exit(1)
elif args[:1] == ['api']:
    if os.environ.get('FAIL_API'):
        print('Release history lookup failed', file=sys.stderr)
        sys.exit(1)
    pages = json.load(open(os.environ['RELEASE_PAGES_FILE']))
    if '--paginate' not in args:
        pages = pages[:1]
    if '--jq' in args:
        expression = args[args.index('--jq') + 1]
        for page in pages:
            result = subprocess.run(['/usr/bin/jq', '-r', expression], input=json.dumps(page),
                                    text=True, capture_output=True)
            sys.stdout.write(result.stdout)
            if result.returncode:
                sys.stderr.write(result.stderr)
                sys.exit(result.returncode)
    else:
        for page in pages:
            print(json.dumps(page))
elif args[:2] == ['release', 'create']:
    if os.environ.get('FAIL_CREATE'):
        print('Simulated release creation failure', file=sys.stderr)
        sys.exit(1)
    print('https://github.com/example/downloads/releases/tag/untagged-test-draft')
elif args[:2] == ['release', 'edit'] and os.environ.get('FAIL_EDIT'):
    sys.exit(1)
''')
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        COMMAND_LOG=str(self.root / 'commands.jsonl'),
                        RELEASE_PAGES_FILE=str(self.pages),
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

    def set_pages(self, pages):
        self.pages.write_text(json.dumps(pages))

    def make_assets(self, version, build):
        tag = f'{version}-{build}'
        assets = self.root / '.build/releases' / tag / 'assets'
        assets.mkdir(parents=True, exist_ok=True)
        dmg = assets / f'MergeHawk-{version[1:]}-{build}-apple-silicon.dmg'
        dmg.write_bytes(b'installer')
        tree = ET.parse(self.feed)
        item = tree.find('./channel/item')
        item.find(NS + 'version').text = build
        item.find(NS + 'shortVersionString').text = version[1:]
        item.find('enclosure').set('url',
            f'https://github.com/{REPO}/releases/download/{tag}/{dmg.name}')
        tree.write(assets / 'appcast.xml')

    def run_release(self, *args, phase='--publish-only', version='v' + VERSION, build=BUILD):
        return subprocess.run(
            ['bash', str(self.root / 'scripts/release-github.sh'), '--version', version,
             '--build', build, *([phase] if phase else []), *args],
            env=self.env, capture_output=True, text=True)

    def isolate_path(self):
        for command in ('bash', 'python3', 'dirname', 'env'):
            (self.bin / command).symlink_to(shutil.which(command))
        self.env['PATH'] = str(self.bin)

    def stub_preparation(self):
        shutil.rmtree(self.assets.parent)
        for command in ('swift', 'codesign', 'hdiutil', 'xcrun', 'spctl', 'ditto', 'sips', 'iconutil'):
            self.command(command, '')
        self.command('uname', "print('arm64')\n")
        self.command('build-app-bundle.sh', '')
        shutil.copy(self.bin / 'build-app-bundle.sh', self.root / 'scripts')
        self.env.update(DEVELOPER_ID_APPLICATION='test-identity', NOTARYTOOL_PROFILE='test-profile')

    def stub_preparation_with_bundle(self, marketing_version):
        self.stub_preparation()
        self.command('build-app-bundle.sh', '''import plistlib
from pathlib import Path
app = Path(os.environ['APP_DIR'])
(app / 'Contents').mkdir(parents=True)
info = {'MergeHawkDistributionChannel': 'github',
        'SUFeedURL': os.environ['SPARKLE_FEED_URL'],
        'SUPublicEDKey': os.environ['SPARKLE_PUBLIC_KEY'],
        'CFBundleVersion': os.environ['BUILD_NUMBER'],
        'CFBundleShortVersionString': os.environ.get('TEST_BUNDLE_VERSION', os.environ['MARKETING_VERSION']),
        'CFBundleIdentifier': 'com.mergehawk.app'}
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(info, output)
''')
        shutil.copy(self.bin / 'build-app-bundle.sh', self.root / 'scripts')
        self.command('generate_appcast', '')
        self.env['SPARKLE_GENERATE_APPCAST'] = str(self.bin / 'generate_appcast')
        self.env['TEST_BUNDLE_VERSION'] = marketing_version

    def calls(self):
        path = self.root / 'commands.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def release_mutations(self):
        return [call for call in self.calls() if call[:2] == ['gh', 'release']]

    def resolve_candidate(self):
        return subprocess.run(
            ['bash', '-c', 'set -euo pipefail; source scripts/lib/release-history.sh; '
             'published_tags="$(list_published_release_tags "$RELEASE_REPOSITORY")"; '
             'printf "%s\\n" "$published_tags" | python3 scripts/lib/release-version.py'],
            cwd=self.root, env={**self.env, 'RELEASE_REPOSITORY': REPO},
            capture_output=True, text=True)

    def test_uploads_only_public_assets_as_draft_before_publishing_latest(self):
        (self.assets / 'private-debug.log').write_text('must not upload')
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        gh = [call for call in self.calls() if call[0] == 'gh']
        self.assertEqual(gh.pop(0)[1:], ['auth', 'status', '--active', '--hostname', 'github.com'])
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
        result = self.run_release('--draft')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Created draft: https://github.com/example/downloads/releases/tag/untagged-test-draft', result.stdout)
        self.assertFalse(any(c[1:3] == ['release', 'edit'] for c in self.calls()))

    def test_failed_upload_does_not_publish(self):
        self.env['FAIL_CREATE'] = '1'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Simulated release creation failure', result.stderr)
        self.assertEqual([c[2] for c in self.release_mutations()], ['create'])

    def test_failed_publication_identifies_uploaded_release_without_deleting_it(self):
        self.env['FAIL_EDIT'] = '1'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not confirm publication of ' + TAG, result.stderr)
        self.assertIn('https://github.com/example/downloads/releases/tag/untagged-test-draft', result.stderr)
        self.assertNotIn('Published:', result.stdout)
        self.assertFalse(any(c[1:3] == ['release', 'delete'] for c in self.calls()))

    def test_combined_release_rejects_missing_authentication_before_building(self):
        self.env['FAIL_AUTH'] = '1'
        result = self.run_release(phase=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('GitHub authentication is unavailable', result.stderr)
        self.assertEqual(self.calls(), [['git', 'status', '--porcelain'],
                                       ['gh', 'auth', 'status', '--active', '--hostname', 'github.com']])

    def test_missing_publishing_tool_is_reported_before_building(self):
        self.isolate_path()
        (self.bin / 'gh').unlink()
        for phase in (None, '--publish-only'):
            with self.subTest(phase=phase):
                result = self.run_release(phase=phase)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Required command not found: gh', result.stderr)

    def test_missing_build_tool_is_reported_before_preparation(self):
        self.isolate_path()
        result = self.run_release(phase='--prepare-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Required command not found: swift', result.stderr)
        self.assertEqual(self.calls(), [['git', 'status', '--porcelain']])

    def test_publication_does_not_require_build_tools(self):
        self.isolate_path()
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Published:', result.stdout)

    def test_missing_sparkle_artifacts_are_reported_before_notarization_without_github(self):
        self.stub_preparation()
        self.env['FAIL_AUTH'] = '1'
        result = self.run_release(phase='--prepare-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not find Sparkle generate_appcast: .build/artifacts is missing', result.stderr)
        self.assertNotIn('find:', result.stderr)
        self.assertTrue(any(c[0] == 'build-app-bundle.sh' for c in self.calls()))
        self.assertFalse(any(c[0] in ('gh', 'xcrun', 'hdiutil') for c in self.calls()))

    def test_remote_query_failure_does_not_create_release(self):
        self.env['FAIL_API'] = '1'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release history lookup failed', result.stderr)
        self.assertEqual(self.release_mutations(), [])

    def test_equal_or_newer_existing_build_cannot_be_replaced(self):
        for published in ('v0.1.0-' + BUILD, 'v0.1.0-20260921123456'):
            with self.subTest(published=published):
                self.set_pages([[release(published)]])
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('must be newer than published build', result.stderr)
                self.assertEqual(self.release_mutations(), [])

    def test_older_existing_build_allows_publication(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_feed_is_rejected_before_github(self):
        for field, value, diagnostic in [('url', 'https://example.com/wrong.dmg', 'Wrong download URL'),
                                         ('length', '100', 'Wrong archive length'),
                                         (NS + 'edSignature', '', 'Missing Sparkle signature')]:
            with self.subTest(field=field):
                original = self.feed.read_bytes()
                tree = ET.parse(self.feed)
                tree.find('./channel/item/enclosure').set(field, value)
                tree.write(self.feed)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(self.release_mutations(), [])
                self.feed.write_bytes(original)
        self.assertFalse(any(c[0] == 'gh' for c in self.calls()))

    def test_feed_requires_matching_marketing_version(self):
        for value in (None, '0.1.0'):
            with self.subTest(value=value):
                original = self.feed.read_bytes()
                tree = ET.parse(self.feed)
                node = tree.find('./channel/item/' + NS + 'shortVersionString')
                if value is None:
                    tree.find('./channel/item').remove(node)
                else:
                    node.text = value
                tree.write(self.feed)
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Wrong marketing version', result.stderr)
                self.assertEqual(self.release_mutations(), [])
                self.feed.write_bytes(original)

    def test_history_filter_and_pagination_select_only_public_stable_releases(self):
        self.set_pages([
            [release(BASELINE), release('v0.1.90-20260919150000', draft=True)],
            [release('v0.1.2-20260919170000'),
             release('v0.1.99-20260919180000', prerelease=True)],
        ])
        result = self.resolve_candidate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0.1.3\n')
        api = [call for call in self.calls() if call[:2] == ['gh', 'api']]
        self.assertEqual(len(api), 1)
        self.assertIn('--paginate', api[0])
        self.assertIn('--jq', api[0])

    def test_history_lookup_or_missing_baseline_stops_resolution(self):
        for pages, fail_api, diagnostic in [([], False, 'Cannot establish a 0.1.x baseline'),
                                            ([[release('v0.2.0-20260919123456')]], False,
                                             'Unsupported or malformed published release tag'),
                                            ([[release(BASELINE)]], True,
                                             'Release history lookup failed')]:
            with self.subTest(pages=pages, fail_api=fail_api):
                self.set_pages(pages)
                if fail_api:
                    self.env['FAIL_API'] = '1'
                else:
                    self.env.pop('FAIL_API', None)
                result = self.resolve_candidate()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(self.release_mutations(), [])

    def test_missing_baseline_blocks_publication(self):
        self.set_pages([[]])
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cannot establish a 0.1.x baseline', result.stderr)
        self.assertEqual(self.release_mutations(), [])

    def test_exact_next_patch_is_required_even_for_drafts(self):
        for version in ('v0.1.0', 'v0.1.2', 'v0.2.0'):
            with self.subTest(version=version):
                self.make_assets(version, BUILD)
                result = self.run_release('--draft', version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f'Requested marketing version {version[1:]}; expected 0.1.1', result.stderr)
                self.assertIn('Prepare again with the next version and a fresh build timestamp', result.stderr)
                self.assertEqual(self.release_mutations(), [])

        self.set_pages([[release(BASELINE), release(TAG)]])
        fresh_build = '20260922123456'
        self.make_assets('v0.1.1', fresh_build)
        result = self.run_release(version='v0.1.1', build=fresh_build)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Requested marketing version 0.1.1; expected 0.1.2', result.stderr)
        self.assertEqual(self.release_mutations(), [])

    def test_preparation_checks_bundle_marketing_version_without_github(self):
        self.stub_preparation_with_bundle('0.1.0')
        self.env['FAIL_AUTH'] = '1'
        result = self.run_release(phase='--prepare-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Wrong bundle marketing version', result.stderr)
        self.assertFalse(any(call[0] in ('gh', 'hdiutil', 'xcrun') for call in self.calls()))

    def test_matching_bundle_metadata_reaches_packaging(self):
        self.stub_preparation_with_bundle(VERSION)
        result = self.run_release(phase='--prepare-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Wrong bundle marketing version', result.stderr)
        self.assertTrue(any(call[0] == 'hdiutil' for call in self.calls()))
        self.assertFalse(any(call[0] == 'gh' for call in self.calls()))

    def test_published_history_alone_controls_candidate_after_attempts(self):
        for failure in ('FAIL_CREATE', 'FAIL_EDIT'):
            with self.subTest(failure=failure):
                self.env[failure] = '1'
                self.assertNotEqual(self.run_release().returncode, 0)
                self.env.pop(failure)
                resolved = self.resolve_candidate()
                self.assertEqual(resolved.returncode, 0, resolved.stderr)
                self.assertEqual(resolved.stdout, '0.1.1\n')
        self.assertEqual(self.run_release('--draft').returncode, 0)
        self.assertEqual(self.resolve_candidate().stdout, '0.1.1\n')
        published = self.run_release()
        self.assertEqual(published.returncode, 0, published.stderr)
        self.set_pages([[release(BASELINE), release(TAG)]])
        resolved = self.resolve_candidate()
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertEqual(resolved.stdout, '0.1.2\n')

    def test_workflow_resolves_before_build_and_passes_both_outputs(self):
        workflow = (ROOT / '.github/workflows/release-github.yml').read_text()
        self.assertIn('group: public-download-release', workflow)
        self.assertIn('GITHUB_REF_PROTECTED', workflow)
        self.assertLess(workflow.index('id: release'), workflow.index('Validate signing configuration'))
        self.assertLess(workflow.index('id: release'), workflow.index('Build signed and notarized installer'))
        self.assertLess(workflow.index('Reject stale source before publication'),
                        workflow.index('Publish public download assets'))
        self.assertIn('current_main="$(gh api', workflow)
        self.assertIn('source scripts/lib/release-history.sh', workflow)
        self.assertIn('published_tags="$(list_published_release_tags "$RELEASE_REPOSITORY")"', workflow)
        self.assertIn('marketing_version="$(printf', workflow)
        self.assertIn('echo "marketing_version=$marketing_version" >> "$GITHUB_OUTPUT"', workflow)
        self.assertIn('echo "build=$build" >> "$GITHUB_OUTPUT"', workflow)
        self.assertEqual(workflow.count('MARKETING_VERSION: ${{ steps.release.outputs.marketing_version }}'), 3)
        self.assertEqual(workflow.count('BUILD_NUMBER: ${{ steps.release.outputs.build }}'), 3)
        self.assertEqual(workflow.count('GH_TOKEN: ${{ github.token }}'), 2)
        self.assertEqual(workflow.count('GH_TOKEN: ${{ secrets.DOWNLOADS_TOKEN }}'), 1)

    def test_invalid_inputs_have_no_external_effects(self):
        for args, diagnostic in [(('--version', 'v0.1.0;touch pwned'), 'Use --version'),
                                 (('--build', '1'), 'Use --version'),
                                 (('--build', '20269920123456'), 'Build number must be a valid UTC'),
                                 (('--version',), 'Missing value for --version')]:
            with self.subTest(args=args):
                result = self.run_release(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
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
