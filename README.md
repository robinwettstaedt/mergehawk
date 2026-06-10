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

## GitHub Release Distribution

MergeHawk's direct-download distribution path uses GitHub Releases and Sparkle.
The committed release defaults live in `scripts/release-github.env`. That file
contains only repo-safe `KEY=value` entries: the public Sparkle appcast URL and
the Sparkle public key embedded in GitHub-distributed app bundles. Release
scripts parse this file as inert configuration data rather than executing it as
shell.

The local release script builds a Developer ID signed app, packages it for
download, notarizes it, generates a Sparkle appcast, and publishes the release
assets with the GitHub CLI:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="mergehawk-notary" \
scripts/release-github.sh \
  --version v0.1.0 \
  --build 1 \
  --draft
```

The Sparkle private key is a signing secret. It is stored in the macOS login
Keychain for local releases and must not be committed. To export it for a
password manager or GitHub Actions secret:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /path/to/sparkle-private-key.txt
```

Store that file's contents in the GitHub Actions secret `SPARKLE_PRIVATE_KEY`,
then delete the exported file.

GitHub Actions can also create draft releases with
`.github/workflows/release-github.yml`. The workflow reads the committed Sparkle
URL/public key defaults and needs these GitHub repository settings:

- Repository variable `DEVELOPER_ID_APPLICATION`
- Optional repository variables `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY` if
  the committed defaults should be overridden
- Repository secrets `SPARKLE_PRIVATE_KEY`,
  `DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64`,
  `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and
  `APPLE_APP_SPECIFIC_PASSWORD`

The workflow targets the `release` GitHub environment. For private repositories
on GitHub Free, Pro, or Team plans, GitHub accepts the environment but does not
support required-reviewer protection rules. After the repository is public, add
the repository owner as a required reviewer for the `release` environment before
publishing non-draft releases.

Run the workflow manually from a protected branch with a version such as
`v0.1.0`. It defaults to a draft release. The workflow creates and pushes the
tag after building from the protected branch; pushing a `v*` tag does not start a
release workflow.

```sh
git checkout main
git pull origin main
gh workflow run "GitHub Release" --ref main -f version=v0.1.0 -f draft=true
```

Keep the workflow on a protected branch, and keep the `release` environment
restricted to trusted reviewers before publishing non-draft releases.

Private repository releases are useful for internal testing, but public Sparkle
updates require the appcast and downloadable app artifact to be reachable
without GitHub authentication.

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

`.env.local` is gitignored. `scripts/update-installed-app.sh` and `scripts/run-agent-app.sh` load it automatically and embed those values into the app bundle launch environment.

MergeHawk does not request broad classic OAuth scopes for GitHub App sign-in. Access is bounded by the signed-in user's GitHub permissions, the MergeHawk GitHub App permissions, and where the app is installed.

After signing in, install or manage repository access from the Sources settings pane. GitHub lets the user choose a personal account or organization, then choose all repositories or selected repositories. Private organization repositories require an organization owner, or an eligible repository admin when the organization allows it, to install or approve the MergeHawk GitHub App for that organization or repository. If MergeHawk is signed in but the app is not installed anywhere, the menu and Sources settings show repository access guidance instead of a normal empty PR state.

GitHub Inbox notifications shown in `Notifications > Other` require the classic personal access token fallback because GitHub App user tokens and fine-grained personal access tokens do not provide the same user notifications API access.

## Advanced Personal Access Token Fallback

1. Create a GitHub fine-grained personal access token for PR data, or a classic personal access token if you need `Notifications > Other`.
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
