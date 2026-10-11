"""Structure checks for the manual release workflow, read as text without a YAML library."""

from pathlib import Path
import re
import unittest

from test_release_version import WORKFLOW_VERSION_PIPELINE


WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/release-github.yml'
GUARD = "if: github.ref == 'refs/heads/main' && github.triggering_actor == github.repository_owner"
STEP_SECRETS = {
    ('build', 'Import signing certificate into temporary Keychain'):
        {'DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64', 'DEVELOPER_ID_CERTIFICATE_PASSWORD'},
    ('build', 'Configure notarization credentials'):
        {'APPLE_ID', 'APPLE_TEAM_ID', 'APPLE_APP_SPECIFIC_PASSWORD'},
    ('build', 'Build signed and notarized release assets'): {'SPARKLE_PRIVATE_KEY'},
}


def parse(text):
    """Split the workflow into its header and jobs, and each job into its header and named steps."""
    lines = text.splitlines()
    jobs_at = lines.index('jobs:')
    header = '\n'.join(lines[:jobs_at])
    jobs = {}
    name = None
    for line in lines[jobs_at + 1:]:
        match = re.fullmatch(r'  ([a-z_-]+):', line)
        if match:
            name = match.group(1)
            jobs[name] = []
        elif name is not None:
            jobs[name].append(line)
    parsed = {}
    for name, body in jobs.items():
        job_header, steps, current = [], {}, None
        for line in body:
            if line.startswith('      - name:'):
                current = line.split(':', 1)[1].strip()
                steps[current] = [line]
            elif current is None:
                job_header.append(line)
            else:
                steps[current].append(line)
        parsed[name] = {'header': '\n'.join(job_header),
                        'steps': {step: '\n'.join(text) for step, text in steps.items()},
                        'text': '\n'.join(body)}
    return header, parsed


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.header, self.jobs = parse(self.text)

    def step(self, job, name):
        return self.jobs[job]['steps'][name]

    def test_only_manual_dispatch_with_bump_choice(self):
        self.assertIn('  workflow_dispatch:', self.header)
        lines = self.header.splitlines()
        self.assertIn('      bump:', lines)
        self.assertIn('        type: choice', lines)
        options_at = lines.index('        options:')
        options = []
        for line in lines[options_at + 1:]:
            if not line.startswith('          - '):
                break
            options.append(line.strip()[2:])
        self.assertEqual(options, ['patch', 'minor', 'major'])
        self.assertNotIn('push:', self.text)
        self.assertNotIn('draft', self.text.lower())

    def test_both_jobs_require_main_and_the_owner(self):
        self.assertEqual(set(self.jobs), {'build', 'publish'})
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertIn('    ' + GUARD, job['header'].splitlines())

    def test_build_job_uses_release_environment_with_read_token(self):
        build = self.jobs['build']
        self.assertIn('    environment: release', build['header'].splitlines())
        self.assertIn('contents: read', build['header'])
        self.assertNotIn('contents: write', build['text'])

    def test_publish_job_writes_without_secrets_or_checkout(self):
        publish = self.jobs['publish']
        self.assertIn('contents: write', publish['header'])
        self.assertIn('    needs: build', publish['header'].splitlines())
        for forbidden in ('environment:', 'secrets.', 'actions/checkout'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, publish['text'])

    def test_each_secret_is_referenced_only_in_its_step(self):
        self.assertNotIn('secrets.', self.header)
        for name, job in self.jobs.items():
            self.assertNotIn('secrets.', job['header'])
            for step, text in job['steps'].items():
                with self.subTest(job=name, step=step):
                    self.assertEqual(set(re.findall(r'secrets\.([A-Za-z0-9_]+)', text)),
                                     STEP_SECRETS.get((name, step), set()))
        for (job, step) in STEP_SECRETS:
            self.assertIn(step, self.jobs[job]['steps'])

    def test_version_step_runs_the_shared_pipeline(self):
        lines = [line.strip() for line in self.step('build', 'Resolve release version').splitlines()]
        start = lines.index(WORKFLOW_VERSION_PIPELINE[0])
        self.assertEqual(lines[start:start + len(WORKFLOW_VERSION_PIPELINE)], WORKFLOW_VERSION_PIPELINE)

    def test_upload_keeps_only_dmg_and_appcast_for_one_day(self):
        upload = self.step('build', 'Upload release assets').splitlines()
        self.assertIn('          retention-days: 1', upload)
        self.assertIn('          if-no-files-found: error', upload)
        path_at = upload.index('          path: |')
        paths = []
        for line in upload[path_at + 1:]:
            if not line.startswith('            '):
                break
            paths.append(line.strip())
        self.assertEqual(len(paths), 2)
        self.assertTrue(paths[0].endswith('-apple-silicon.dmg'), paths[0])
        self.assertTrue(paths[1].endswith('/appcast.xml'), paths[1])

    def test_publish_checks_main_and_tag_before_creating_release(self):
        publish = self.step('publish', 'Publish release').replace('\\\n', ' ')
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq .object.sha', publish)
        self.assertIn('"$GITHUB_SHA"', publish)
        self.assertIn('matching-refs/tags/v$VERSION', publish)
        (create,) = [line for line in publish.splitlines() if line.strip().startswith('gh release create')]
        for flag in ('--target "$GITHUB_SHA"', '--generate-notes', '--latest', '--fail-on-no-commits'):
            with self.subTest(flag=flag):
                self.assertIn(flag, create)
        self.assertLess(publish.index('git/ref/heads/main'), publish.index('matching-refs/tags'))
        self.assertLess(publish.index('matching-refs/tags'), publish.index('gh release create'))

    def test_no_old_downloads_channel_or_tracing(self):
        # Split so the repository-wide search for the old channel names finds no match here.
        for forbidden in ('DOWNLOADS' + '_TOKEN', 'mergehawk' + '-downloads', 'set -x', 'xtrace'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, self.text)

    def test_every_action_is_pinned_to_a_commit(self):
        uses = re.findall(r'uses:\s*(\S+)', self.text)
        self.assertTrue(uses)
        for action in uses:
            with self.subTest(action=action):
                self.assertRegex(action, r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$')

    def test_releases_run_one_at_a_time(self):
        lines = self.header.splitlines()
        self.assertIn('concurrency:', lines)
        self.assertIn('  group: release', lines)
        self.assertIn('  cancel-in-progress: false', lines)


if __name__ == '__main__':
    unittest.main()
