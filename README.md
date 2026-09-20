# MergeHawk

Native macOS menu bar dashboard for scanning GitHub pull requests and intentional notifications.

Shared project terminology lives in [docs/glossary.md](docs/glossary.md).

## Current state

- SwiftPM project with a macOS 14+ AppKit/SwiftUI menu bar app.
- `LSUIElement`-style accessory behavior at runtime with no Dock presence.
- Native `NSStatusItem` menu populated with SwiftUI-hosted dashboard rows.
- Compact menu tabs for `Notifications` and `My PRs`.
- SwiftUI Settings window with General, GitHub, Notifications, and Sources panes.
- First-sync silent baseline behavior.
- Event detection for new comments, new reviews, failed CI, and changes requested.
- Notification preferences for in-menu and macOS notifications.
- GitHub App sign-in through the GitHub device flow.
- GitHub PR fetching through GraphQL search.
- GitHub App user token storage in macOS Keychain.
- Advanced GitHub PAT fallback in Settings.

GitHub Enterprise Server, widgets, multi-account support, and extra PR tabs are deferred.

## Run

Build and launch the native menu bar app:

```sh
swift run mergehawk
```

Without GitHub credentials, MergeHawk shows a GitHub App sign-in action in the menu and does not display pull request data.

Build a local `.app` bundle with `LSUIElement`:

```sh
scripts/build-app-bundle.sh
open .build/MergeHawk.app
```

Update the locally installed app bundle and restart it:

```sh
scripts/update-installed-app.sh
```

By default this updates `/Applications/MergeHawk.app` if present, then
`~/Applications/MergeHawk.app` if present, otherwise it installs to
`~/Applications/MergeHawk.app`. To update a specific bundle:

```sh
APP_PATH="/path/to/MergeHawk.app" scripts/update-installed-app.sh
```

## Public downloads and in-app software updates

The source repository stays private. The separate public
[`mergehawk-downloads`](https://github.com/robinwettstaedt/mergehawk-downloads/releases)
repository contains a README and GitHub Releases with **only the signed,
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
commit. Do not mirror or push the private source repository into it.
`scripts/release-github.env` contains the explicit release destination,
public appcast URL, and existing Sparkle public key. Scripts parse those files
as inert `KEY=value` configuration, never as shell code.

Configure the following in the **private source repository**, either as
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

Each build uses a UTC `YYYYMMDDHHMMSS` bundle version, preserving ordering with
previous private installers. The marketing version remains `0.1.0`; change
`MARKETING_VERSION` in the workflow when needed. Release tags include both,
for example `v0.1.0-20260920123456`. GitHub creates these tags on the downloads
repository's own default branch. A release starts as a draft with its DMG and
appcast uploaded, then becomes public and latest. Failed uploads never advance
the public feed. Publishing a build older than an existing published build is
rejected. Keep publication through this serialized workflow; concurrent local
publishing is not supported. Drafts do not offer software updates; to publish
one later, run a fresh non-draft workflow so version ordering is checked.

To create a draft manually:

```sh
gh workflow run "GitHub Release" --ref main -f draft=true
```

### Local release tooling

The workflow and local releases share `scripts/release-github.sh`:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="mergehawk-notary" \
scripts/release-github.sh --version v0.1.0 --build "$(date -u +%Y%m%d%H%M%S)" --draft
```

Run from a clean worktree on an Apple Silicon Mac with Xcode, signing credentials,
and `gh` authenticated for the downloads repository. `NOTARYTOOL_KEYCHAIN` can
select the notarization Keychain. Sparkle uses the local Keychain signing key
(account `ed25519` by default), or `SPARKLE_PRIVATE_KEY` in CI.
`--prepare-only` builds and verifies assets without GitHub authentication;
`--publish-only` publishes those same assets without rebuilding. Prepared files
are under `.build/releases/<tag>/`; only the DMG and appcast are uploaded.
Use a new timestamp to retry a failed preparation. `--dry-run --allow-dirty`
prints the plan without building or publishing.

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

### When the source repository becomes public

Make a clean cut: change `RELEASE_REPOSITORY` and `SPARKLE_FEED_URL` to the main
repository, configure publishing credentials for that destination, and publish
the first public version there. Manually install that version once; its later
updates will come from the main repository. After the sole initial user has
switched, archive or delete `mergehawk-downloads`. No feed migration or bridge
release is needed. Preserve the app identity and signing keys.

## GitHub App Setup

MergeHawk signs in through a GitHub App user access token. Before validating real GitHub auth, create the app in GitHub:

1. Open GitHub, then go to **Settings** > **Developer settings** > **GitHub Apps**.
2. Click **New GitHub App**.
3. Use `MergeHawk` as the application name.
4. Use `https://github.com/robinwettstaedt/mergehawk` as the homepage URL.
5. Leave the callback URL field blank (device flow does not use a callback URL).
6. Keep **Expire user authorization tokens** enabled.
7. Leave **Request user authorization (OAuth) during installation** disabled.
8. Enable **Device Flow**.
9. Select **Any account** for installation.
10. Use these repository permissions:
    - Metadata: Read-only
    - Pull requests: Read-only
    - Issues: Read-only
    - Checks: Read-only
    - Commit statuses: Read-only
11. Leave organization permissions empty.
12. Register the app. No client secret is required.
13. For local development overrides, save the credentials in `.env.local`:

```sh
MERGEHAWK_GITHUB_APP_ID="..."
MERGEHAWK_GITHUB_APP_CLIENT_ID="..."
MERGEHAWK_GITHUB_APP_INSTALL_URL="https://github.com/apps/mergehawk/installations/new"
MERGEHAWK_GITHUB_APP_MANAGE_URL="https://github.com/settings/apps/authorizations"
```

`.env.local` is gitignored. `scripts/update-installed-app.sh` loads it automatically and embeds those values into the normal app bundle launch environment. Verification slot apps are mock-only and do not embed these credentials.

MergeHawk does not request broad classic OAuth scopes for GitHub App sign-in. Access is bounded by the signed-in user's GitHub permissions, the MergeHawk GitHub App permissions, and where the app is installed.

After signing in, install or manage repository access from the Sources settings pane. GitHub lets the user choose a personal account or organization, then choose all repositories or selected repositories. Private organization repositories require an organization owner, or an eligible repository admin when the organization allows it, to install or approve the MergeHawk GitHub App for that organization or repository. If MergeHawk is signed in but the app is not installed anywhere, the menu and Sources settings show repository access guidance instead of a normal empty PR state.

## Advanced Personal Access Token Fallback

1. Create a GitHub fine-grained or classic personal access token for PR data.
2. Grant repository access for the repositories MergeHawk should monitor.
3. Include read permissions for metadata, pull requests, issues, and actions where applicable.
4. Launch the app with `swift run mergehawk`.
5. Open Settings, then the GitHub pane.
6. Paste only the token value, for example `github_pat_...`, with no surrounding text.
7. Click **Connect with token**.

MergeHawk validates the token by fetching the current GitHub user, stores it in Keychain, and then syncs PRs.

## Test

SwiftPM package validation:

```sh
swift test
```

Core behavior tests:

```sh
swift run mergehawkcoretestrunner
```

Build the app:

```sh
swift build --product mergehawk
```
