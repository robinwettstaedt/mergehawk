# Releasing

Releases are published to the separate public
[`mergehawk-downloads`](https://github.com/robinwettstaedt/mergehawk-downloads/releases)
repository. It holds a README and GitHub Releases with **only the signed,
notarized DMG and Sparkle appcast**. No source commits, source tags, build logs,
or credentials are copied there. GitHub's automatic source archives contain
only the downloads repository's README.

The **GitHub Release** workflow builds the triggering commit after every push
to protected `main`, including PR merges. It can also be started manually from
`main`, optionally as a draft. The former automatic private-installer workflow
is replaced by this one workflow. The **CI / Tests** PR check runs Swift tests,
the core test runner, and release publication tests before merge.

Install the first download manually: quit MergeHawk, open the DMG, and replace
MergeHawk in Applications. Old private installers have updates disabled.
Subsequent downloads use the existing in-app **Check for Updates** action and
software-update settings. Builds require Apple Silicon and macOS 14 or later.

### Repository setup

The downloads repository must be public and initialized with its own README
commit. Do not mirror or push the source repository into it.
`scripts/release-github.env` contains the explicit release destination,
public appcast URL, and existing Sparkle public key. Scripts parse those files
as inert `KEY=value` configuration, never as shell code.

Configure the following in the **source repository**, either as
repository settings or in its existing `release` environment:

- Variable `DEVELOPER_ID_APPLICATION` with the Developer ID signing identity.
- Secrets `DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64`,
  `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and
  `APPLE_APP_SPECIFIC_PASSWORD` for signing and notarization.
- Secret `SPARKLE_PRIVATE_KEY`, matching the committed public key.
- Secret `DOWNLOADS_TOKEN`: a fine-grained GitHub personal access token with
  access to **only `mergehawk-downloads`**, **Contents: Read and write** and
  the required metadata access. Set an expiration and replace the secret when
  rotating it. The source repository's automatic `GITHUB_TOKEN` cannot publish
  to another repository.

The publishing token is exposed only to the publication step. Source checkout
uses read-only permissions and does not retain Git credentials. Signing and
notarization credentials use a temporary Keychain removed after the job.
Keep `main` protected: only trusted code should receive release credentials.
The workflow serializes publications and does not cancel an active release.
Before publishing, it rejects builds whose source commit is no longer current
`main`, including reruns of old workflow runs.

Before building, the workflow reads published stable releases in the downloads
repository and selects the next `0.1.x` patch. For example, published `0.1.0`
releases select `0.1.1`; after `0.1.1` becomes public, the next run selects
`0.1.2`. Pushes to `main`, manual runs, and reruns all use the same rule.
Failures, superseded builds, and unpublished drafts leave that patch available
for a fresh run. The workflow stops before building if no published stable
`0.1.x` baseline exists or release history cannot be read.

Each build still uses a UTC `YYYYMMDDHHMMSS` bundle version, preserving
ordering with previous private installers. Release tags include both versions,
for example `v0.1.1-20260920123456`. GitHub creates these tags on the downloads
repository's own default branch. A release starts as a draft with its DMG and
appcast uploaded, then becomes public and latest. Publishing a build older
than an existing published build is rejected. Keep publication through this
serialized workflow; concurrent local publishing is not supported. Drafts do
not offer software updates; to publish one later, run a fresh non-draft
workflow so version and build ordering are checked.

To create a draft manually:

```sh
gh workflow run "GitHub Release" --ref main -f draft=true
```

### Local release tooling

The workflow and local releases share `scripts/release-github.sh`. Local callers
provide an explicit version; publication requires it to be exactly the next
`0.1.x` patch after the published stable releases. For example, if `0.1.0` is
the highest published patch, use:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="mergehawk-notary" \
scripts/release-github.sh --version v0.1.1 --build "$(date -u +%Y%m%d%H%M%S)" --draft
```

Run from a clean worktree on an Apple Silicon Mac with Xcode, signing credentials,
and `gh` authenticated for the downloads repository. `NOTARYTOOL_KEYCHAIN` can
select the notarization Keychain. Sparkle uses the local Keychain signing key
(account `ed25519` by default), or `SPARKLE_PRIVATE_KEY` in CI.
`--prepare-only` builds and verifies assets without GitHub authentication;
`--publish-only` publishes those same assets without rebuilding. Prepared files
are under `.build/releases/<tag>/`; only the DMG and appcast are uploaded.
Use a new timestamp to retry a failed preparation. An attempt that leaves no
public release keeps the patch available; prepare again with a fresh timestamp
before another attempt. `--dry-run --allow-dirty` prints the plan without
building or publishing.

The gitignored `scripts/release-github.local.env` can hold both local release
settings and the credential fields consumed by
`scripts/configure-github-release-secrets.sh`. That helper also requires
`DOWNLOADS_TOKEN`; `--dry-run` validates configuration without uploading it.
The release script ignores bootstrap credentials in that shared file and uses
its saved Keychain profiles and `gh` authentication instead.

Run the focused release tests without creating worktree cache files:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/release -v
```

The old `scripts/build-private-installer.sh` remains available for an explicitly
requested local installer with updates disabled; it is no longer run by CI.

### Moving releases into the source repository

Moving releases to the main repository requires a separate baseline migration
plan: the release workflow cannot select a version from an empty destination.
At cutover, update `RELEASE_REPOSITORY` and `SPARKLE_FEED_URL`, configure
publishing credentials for that destination, and preserve the app identity and
signing keys. Plan how existing installations will move to the new feed before
archiving `mergehawk-downloads`.
