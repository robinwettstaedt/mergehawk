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
- GitHub OAuth sign-in through a browser loopback callback.
- GitHub PR fetching through GraphQL search.
- OAuth credential storage in macOS Keychain.
- Advanced GitHub PAT fallback in Settings.

GitHub Enterprise Server, device flow, auto-updates, widgets, multi-account support, and extra PR tabs are deferred.

## Run

Build and launch the native menu bar app:

```sh
swift run mergehawk
```

Without GitHub credentials, MergeHawk shows a GitHub OAuth sign-in action in the menu and does not display pull request data.

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

## GitHub OAuth App Setup

MergeHawk signs in through a GitHub OAuth App. Before validating real OAuth, create the app in GitHub:

1. Open GitHub, then go to **Settings** > **Developer settings** > **OAuth Apps**.
2. Click **New OAuth App**.
3. Use `MergeHawk` as the application name.
4. Use `https://github.com/robinwettstaedt/mergehawk` as the homepage URL.
5. Use `http://127.0.0.1:53683/callback` as the authorization callback URL.
6. Leave Device Flow disabled.
7. Register the app and generate a client secret.
8. Save the credentials in `.env.local`:

```sh
MERGEHAWK_GITHUB_OAUTH_APP_ID="..."
MERGEHAWK_GITHUB_OAUTH_CLIENT_ID="..."
MERGEHAWK_GITHUB_OAUTH_CLIENT_SECRET="..."
```

`.env.local` is gitignored. `scripts/update-installed-app.sh` and `scripts/run-agent-app.sh` load it automatically and embed those values into the app bundle launch environment.

MergeHawk requests `read:user read:org repo notifications`. GitHub OAuth's `repo` scope is broad and required for private repository PR workflows; `read:org` is required for team review-request metadata. MergeHawk only performs read API calls.

Organization OAuth restrictions or SAML SSO may require an organization owner or the signed-in user to approve/authorize MergeHawk before private organization resources are visible.

## Advanced Personal Access Token Fallback

1. Create a GitHub fine-grained personal access token.
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
