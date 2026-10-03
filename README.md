# MergeHawk

Native macOS menu bar dashboard for scanning GitHub pull requests and intentional notifications.

Shared project terminology lives in [docs/glossary.md](docs/glossary.md).

## Current state

- SwiftPM project with a macOS 14+ AppKit/SwiftUI menu bar app.
- `LSUIElement`-style accessory behavior at runtime with no Dock presence.
- Native `NSStatusItem` menu populated with SwiftUI-hosted dashboard rows.
- Compact menu tabs for `Notifications`, `My PRs`, and `Requested`.
- SwiftUI Settings window with General, GitHub, Notifications, and Sources panes.
- First-sync silent baseline behavior.
- Event detection for new comments, review decisions, failed CI, and newly added mentions.
- Notification preferences for in-menu and macOS notifications, including per-relationship
  comment modes.
- GitHub App sign-in through the GitHub device flow.
- Complete GitHub PR discovery and paginated activity fetching through GraphQL.
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

### When the source repository becomes public

Moving releases to the main repository requires a separate baseline migration
plan: the release workflow cannot select a version from an empty destination.
At cutover, update `RELEASE_REPOSITORY` and `SPARKLE_FEED_URL`, configure
publishing credentials for that destination, and preserve the app identity and
signing keys. Plan how existing installations will move to the new feed before
archiving `mergehawk-downloads`.

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

Dashboard refreshes discover every currently relevant PR, hydrate complete paginated
comment/review activity, reconcile PRs that disappeared from search, and then publish
the dashboard, notification history, and processed-activity record together. A failed
refresh leaves the previous dashboard intact. `Notifications` contains the local PR
notification history directly, including final activity from a PR that was just merged
or closed. Repository catalog and GitHub App installation checks belong to `Sources`;
they refresh separately and cannot delay PR publication.

## Notification settings

The Notifications pane has two matrices for the PRs MergeHawk already tracks: PRs you
authored, PRs assigned to you, and PRs where your review is requested directly or
through a team. Comment settings never add PRs to that set.

- **Pull request notifications** covers review decisions (approvals and changes
  requested), failed CI, becoming assigned or requested, and Ready for review: a draft
  PR you are assigned to or asked to review becoming ready for review. Ready for review
  updates are never produced for PRs you authored.
- **Comment notifications** chooses one mode per relationship: **All comments**,
  **Mentions & threads you joined**, or **Off**. Authored and assigned PRs default to
  All comments; direct and team review requests default to Mentions & threads you joined.

Comment modes cover conversation comments, inline review comments and replies, and
the summary text of comment-only reviews. The summary of an approval or a changes
request belongs to its review decision and never creates a separate comment update.
Mentions & threads you joined keeps comments that mention you directly and new comments
in review threads where your published comments are still present. A mention added by
editing an already seen comment notifies once when a refresh observes it. The in-app
history keeps the newest 100 notifications.

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

Isolated mock launches support deterministic complete-refresh scenarios:

```sh
scripts/run-agent-app.sh --slot local --mock --mock-scenario delayed-refresh --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario refresh-failure --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario merged-final-activity --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario quiet-access-loss --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario bot-notifications --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario comment-notifications --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario long-lists --ui menu --open
```

Each scenario publishes a baseline first; use the menu refresh action to trigger
the selected delay, failure, final merged activity, quiet retirement, or update batch.
The `bot-notifications` scenario has a quiet baseline followed by 10 bot and two
human updates. In a fresh fixture, enable “Mute bot comment and review
notifications” in Settings before the update refresh to see only the two human
in-app rows and notification payloads. Enabling it after the refresh preserves
already retained notification history.
The `comment-notifications` scenario covers all four relationships with the default
comment modes: the first refresh adds eight eligible updates (general comments,
individual inline comments beside an approval, a joined-thread reply, and mentions),
the second adds a mention to an already seen comment, and later refreshes change
nothing.
The `long-lists` scenario has 20 authored and 20 review-request pull requests so the
Authored and Requested lists overflow the menu; the first refresh adds a comment to
each, which fills the Notifications list past its visible height.

When reusing one verification run, give each additional launch a unique `--stage`
such as `app-final-activity`. This keeps its app log and mock notification JSONL
immutable while the default first launch remains the `app` stage.
