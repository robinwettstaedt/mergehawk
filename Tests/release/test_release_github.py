"""Exercise the build-only release script with isolated files and external-command doubles."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = '20260920123456'
VERSION = '1.2.3'
TAG = 'v' + VERSION
REPO = 'example/mergehawk'
FEED_URL = f'https://github.com/{REPO}/releases/latest/download/appcast.xml'
DOWNLOAD_PREFIX = f'https://github.com/{REPO}/releases/download/{TAG}/'
DMG_NAME = f'MergeHawk-{VERSION}-apple-silicon.dmg'
SPARKLE_KEY = 'sparkle-private-test-key'

# Every double refuses to run when the Sparkle signing key reaches its environment.
KEY_GUARD = '''if 'SPARKLE_PRIVATE_KEY' in os.environ:
    sys.exit('SPARKLE_PRIVATE_KEY reached ' + os.path.basename(sys.argv[0]))
'''

GENERATE_APPCAST = '''import plistlib
from pathlib import Path
import xml.etree.ElementTree as ET
args = sys.argv[1:]
key = ''
if '--ed-key-file' in args:
    assert args[args.index('--ed-key-file') + 1] == '-'
    key = sys.stdin.read()
Path(os.environ['APPCAST_KEY_RECORD']).write_text('received' if key else 'missing')
prefix = args[args.index('--download-url-prefix') + 1]
assets = Path(args[-1])
dmg = next(assets.glob('*.dmg'))
info = plistlib.loads(dmg.read_bytes())
build = info['CFBundleVersion']
url = prefix + dmg.name
length = dmg.stat().st_size
short_version = info['CFBundleShortVersionString']
signature = 'test-signature'
defect = os.environ.get('TEST_APPCAST_DEFECT', '')
if defect == 'url':
    url = 'https://example.com/' + dmg.name
elif defect == 'url_build_suffix':
    url = (prefix.rstrip('/') + '-' + build + '/'
           + dmg.name.replace('-apple-silicon', '-' + build + '-apple-silicon'))
elif defect == 'length':
    length += 1
elif defect == 'signature':
    signature = ''
elif defect == 'marketing_version':
    short_version = '0.0.1'
elif defect == 'build':
    build = '20200101000000'
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss')
item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
ET.SubElement(item, '{%s}version' % ns).text = build
ET.SubElement(item, '{%s}shortVersionString' % ns).text = short_version
ET.SubElement(item, 'enclosure', {'url': url, 'length': str(length),
                                  '{%s}edSignature' % ns: signature})
ET.ElementTree(rss).write(assets / 'appcast.xml')
'''


class ReleaseBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        (scripts / 'lib').mkdir(parents=True)
        shutil.copy(ROOT / 'scripts/release-github.sh', scripts)
        shutil.copy(ROOT / 'scripts/lib/release-env.sh', scripts / 'lib')
        self.env_file = scripts / 'release-github.env'
        self.env_file.write_text(f'RELEASE_REPOSITORY="{REPO}"\nSPARKLE_PUBLIC_KEY="test-key"\n')
        self.assets = self.root / '.build/releases' / f'{TAG}-{BUILD}' / 'assets'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.command('git', '''if sys.argv[1:] != ['status', '--porcelain']:
    sys.exit('Unexpected git operation')
''')
        self.command('gh', '')
        # Real tools the script runs directly, wrapped so they refuse the Sparkle key too.
        self.guarded_passthrough('python3', sys.executable)
        self.guarded_passthrough('dirname', shutil.which('dirname'))
        self.key_record = self.root / 'appcast-key-record'
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        COMMAND_LOG=str(self.root / 'commands.jsonl'),
                        APPCAST_KEY_RECORD=str(self.key_record),
                        RELEASE_ENV_FILE=str(self.env_file),
                        RELEASE_LOCAL_ENV_FILE=str(self.root / 'no-local-env'))
        for name in ('RELEASE_REPOSITORY', 'SPARKLE_PRIVATE_KEY', 'SPARKLE_GENERATE_APPCAST',
                     'NOTARYTOOL_KEYCHAIN', 'SPARKLE_KEY_ACCOUNT'):
            self.env.pop(name, None)

    def command(self, name, code):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\n'
                        'import json, os, sys\n'
                        'with open(os.environ["COMMAND_LOG"], "a") as log:\n'
                        '    log.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")\n'
                        + KEY_GUARD + code)
        path.chmod(0o755)

    def guarded_passthrough(self, name, real):
        path = self.bin / name
        path.write_text('#!/bin/bash\n'
                        'if [[ -n "${SPARKLE_PRIVATE_KEY+set}" ]]; then\n'
                        f'  echo "SPARKLE_PRIVATE_KEY reached {name}" >&2\n'
                        '  exit 97\n'
                        'fi\n'
                        f'exec "{real}" "$@"\n')
        path.chmod(0o755)

    def run_release(self, *args, version='v' + VERSION, build=BUILD):
        return subprocess.run(
            ['bash', str(self.root / 'scripts/release-github.sh'), '--version', version,
             '--build', build, *args],
            env=self.env, capture_output=True, text=True)

    def isolate_path(self):
        for command in ('bash', 'env'):
            (self.bin / command).symlink_to(shutil.which(command))
        self.env['PATH'] = str(self.bin)

    def stub_preparation(self):
        for command in ('swift', 'codesign', 'spctl', 'sips', 'iconutil'):
            self.command(command, '')
        self.command('hdiutil', '''from pathlib import Path
args = sys.argv[1:]
if args[:1] == ['create']:
    info = Path(args[args.index('-srcfolder') + 1]) / 'MergeHawk.app/Contents/Info.plist'
    Path(args[-1]).write_bytes(info.read_bytes() if info.exists() else b'disk image')
''')
        self.command('ditto', '''import shutil
from pathlib import Path
if Path(sys.argv[1]).exists():
    shutil.copytree(sys.argv[1], sys.argv[2], symlinks=True)
''')
        self.command('xcrun', '''args = sys.argv[1:]
if args[:2] == ['notarytool', 'submit']:
    print(json.dumps({'status': os.environ.get('TEST_NOTARY_STATUS', 'Accepted')}))
''')
        self.command('uname', "print('arm64')\n")
        self.command('build-app-bundle.sh', '')
        shutil.copy(self.bin / 'build-app-bundle.sh', self.root / 'scripts')
        self.env.update(DEVELOPER_ID_APPLICATION='test-identity', NOTARYTOOL_PROFILE='test-profile')

    def stub_preparation_with_bundle(self, marketing_version=VERSION):
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
        self.command('generate_appcast', GENERATE_APPCAST)
        self.env['SPARKLE_GENERATE_APPCAST'] = str(self.bin / 'generate_appcast')
        self.env['TEST_BUNDLE_VERSION'] = marketing_version

    def calls(self):
        path = self.root / 'commands.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def called(self, name):
        return [call for call in self.calls() if call[0] == name]

    def test_full_preparation_hands_sparkle_key_only_to_generate_appcast(self):
        self.stub_preparation_with_bundle()
        self.env['SPARKLE_PRIVATE_KEY'] = SPARKLE_KEY
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'Prepared release assets: {self.assets}', result.stdout)
        self.assertEqual(self.called('gh'), [])
        self.assertEqual(sorted(path.name for path in self.assets.iterdir()), [DMG_NAME, 'appcast.xml'])
        self.assertEqual(self.key_record.read_text(), 'received')
        (appcast,) = self.called('generate_appcast')
        self.assertEqual(appcast[1:3], ['--ed-key-file', '-'])
        for tool in ('build-app-bundle.sh', 'codesign', 'hdiutil', 'xcrun', 'spctl', 'ditto'):
            self.assertTrue(self.called(tool), tool)
        self.assertNotIn(SPARKLE_KEY, result.stdout + result.stderr)
        self.assertNotIn(SPARKLE_KEY, (self.root / 'commands.jsonl').read_text())

    def test_bundle_feed_url_is_derived_from_configured_repository(self):
        self.stub_preparation_with_bundle()
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.assets / DMG_NAME).read_bytes())
        self.assertEqual(info['SUFeedURL'], FEED_URL)
        (appcast,) = self.called('generate_appcast')
        self.assertEqual(appcast[1:5], ['--account', 'ed25519', '--download-url-prefix', DOWNLOAD_PREFIX])
        self.assertEqual(self.key_record.read_text(), 'missing')

    def test_defective_appcast_fails_before_assets_are_reported(self):
        self.stub_preparation_with_bundle()
        for defect, diagnostic in [('url', 'Wrong download URL'),
                                   ('url_build_suffix', 'Wrong download URL'),
                                   ('length', 'Wrong archive length'),
                                   ('signature', 'Missing Sparkle signature'),
                                   ('marketing_version', 'Wrong marketing version'),
                                   ('build', 'Wrong build')]:
            with self.subTest(defect=defect):
                shutil.rmtree(self.root / '.build', ignore_errors=True)
                self.env['TEST_APPCAST_DEFECT'] = defect
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn('Prepared release assets', result.stdout)

    def test_rejected_notarization_fails_before_stapling(self):
        self.stub_preparation_with_bundle()
        self.env['TEST_NOTARY_STATUS'] = 'Invalid'
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Notarization was not accepted: Invalid', result.stderr)
        self.assertFalse(any(call[1:2] == ['stapler'] for call in self.called('xcrun')))
        self.assertEqual(self.called('generate_appcast'), [])

    def test_removed_publish_flags_are_unknown_arguments(self):
        for flag in ('--publish-only', '--prepare-only', '--draft'):
            with self.subTest(flag=flag):
                result = self.run_release(flag)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Unknown argument: ' + flag, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_local_settings_with_secret_or_feed_keys_are_rejected(self):
        self.stub_preparation_with_bundle()
        local = self.root / 'scripts/release-github.local.env'
        self.env['RELEASE_LOCAL_ENV_FILE'] = str(local)
        for key in ('SPARKLE_PRIVATE_KEY', 'APPLE_APP_SPECIFIC_PASSWORD', 'SPARKLE_FEED_URL'):
            with self.subTest(key=key):
                local.write_text(f'DEVELOPER_ID_APPLICATION=local-identity\n{key}=private-test-value\n')
                result = self.run_release()
                self.assertEqual(result.returncode, 2)
                self.assertIn('Unsupported release env key', result.stderr)
                self.assertIn(key, result.stderr)
                self.assertNotIn('private-test-value', result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])

    def test_local_settings_with_non_secret_keys_are_used(self):
        self.stub_preparation_with_bundle()
        appcast = self.env.pop('SPARKLE_GENERATE_APPCAST')
        for name in ('DEVELOPER_ID_APPLICATION', 'NOTARYTOOL_PROFILE'):
            self.env.pop(name)
        local = self.root / 'scripts/release-github.local.env'
        local.write_text('\n'.join([
            f'RELEASE_REPOSITORY="{REPO}"',
            'SPARKLE_PUBLIC_KEY="test-key"',
            'DEVELOPER_ID_APPLICATION="local-identity"',
            'NOTARYTOOL_PROFILE=local-profile',
            'NOTARYTOOL_KEYCHAIN=/tmp/local.keychain-db',
            f'SPARKLE_GENERATE_APPCAST={appcast}',
            'SPARKLE_KEY_ACCOUNT=local-account',
        ]) + '\n')
        self.env['RELEASE_LOCAL_ENV_FILE'] = str(local)
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['codesign', '--force', '--timestamp', '--sign', 'local-identity',
                       str(self.assets / DMG_NAME)], self.calls())
        (submit,) = [call for call in self.called('xcrun') if call[1:3] == ['notarytool', 'submit']]
        self.assertEqual(submit[4:8], ['--keychain-profile', 'local-profile',
                                       '--keychain', '/tmp/local.keychain-db'])
        (generate,) = self.called('generate_appcast')
        self.assertEqual(generate[1:3], ['--account', 'local-account'])

    def test_invalid_release_configuration_has_no_external_effects(self):
        for contents, diagnostic in [
                ('RELEASE_REPOSITORY="mergehawk"\nSPARKLE_PUBLIC_KEY="test-key"\n',
                 'RELEASE_REPOSITORY must identify owner/repository'),
                (f'RELEASE_REPOSITORY="{REPO}"\nSPARKLE_PUBLIC_KEY=""\n',
                 'Configure the public Sparkle key')]:
            with self.subTest(contents=contents):
                self.env_file.write_text(contents)
                result = self.run_release()
                self.assertEqual(result.returncode, 2)
                self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_build_tool_is_reported_before_preparation(self):
        self.isolate_path()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Required command not found: swift', result.stderr)
        self.assertEqual(self.calls(), [['git', 'status', '--porcelain']])

    def test_missing_sparkle_artifacts_are_reported_before_notarization(self):
        self.stub_preparation()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not find Sparkle generate_appcast: .build/artifacts is missing', result.stderr)
        self.assertNotIn('find:', result.stderr)
        self.assertTrue(self.called('build-app-bundle.sh'))
        self.assertFalse(any(call[0] in ('gh', 'xcrun', 'hdiutil') for call in self.calls()))

    def test_bundle_marketing_version_mismatch_is_rejected(self):
        self.stub_preparation_with_bundle('1.2.2')
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Wrong bundle marketing version', result.stderr)
        self.assertFalse(any(call[0] in ('gh', 'hdiutil', 'xcrun') for call in self.calls()))

    def test_invalid_inputs_have_no_external_effects(self):
        for args, diagnostic in [(('--version', 'v1.0.0;touch pwned'), 'Use --version'),
                                 (('--version', 'v1.0.0-20260920123456'), 'Use --version'),
                                 (('--build', '1'), 'Use --version'),
                                 (('--build', '20269920123456'), 'Build number must be a valid UTC'),
                                 (('--allow-dirty',), '--allow-dirty is only supported with --dry-run'),
                                 (('--version',), 'Missing value for --version')]:
            with self.subTest(args=args):
                result = self.run_release(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_dry_run_prints_derived_plan_without_calls(self):
        result = self.run_release('--dry-run', '--allow-dirty')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Sparkle feed: ' + FEED_URL, result.stdout)
        self.assertIn('tag: ' + TAG + '\n', result.stdout)
        self.assertIn('Installer: ' + DOWNLOAD_PREFIX + DMG_NAME, result.stdout)
        self.assertNotIn('draft', result.stdout.lower())
        self.assertEqual(self.calls(), [])

    def test_committed_config_targets_the_main_repository(self):
        self.env['RELEASE_ENV_FILE'] = str(ROOT / 'scripts/release-github.env')
        result = self.run_release('--dry-run', '--allow-dirty')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Sparkle feed: https://github.com/robinwettstaedt/mergehawk/releases/latest/download/appcast.xml',
                      result.stdout)
        self.assertIn('RELEASE_REPOSITORY="robinwettstaedt/mergehawk"\n',
                      (ROOT / 'scripts/release-github.env').read_text())

    def test_script_never_enables_command_tracing(self):
        script = (ROOT / 'scripts/release-github.sh').read_text()
        self.assertIsNone(re.search(r'set\s+-[A-Za-z]*x|xtrace', script))


if __name__ == '__main__':
    unittest.main()
