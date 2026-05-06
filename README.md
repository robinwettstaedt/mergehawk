# vc-dash

Native macOS menu bar dashboard for scanning GitHub pull requests and intentional notifications.

## Current state

- SwiftPM project with a macOS 14+ AppKit/SwiftUI menu bar app.
- `LSUIElement`-style accessory behavior at runtime with no Dock presence.
- Native `NSStatusItem` menu populated with SwiftUI-hosted dashboard rows.
- Compact menu tabs for `Notifications` and `My PRs`.
- SwiftUI Settings window with General, GitHub, Notifications, Display, and About panes.
- First-sync silent baseline behavior.
- Event detection for new comments, new reviews, failed CI, and changes requested.
- Notification preferences for in-menu and macOS notifications.
- GitHub PAT validation through REST `/user`.
- GitHub PR fetching through GraphQL search.
- PAT storage in macOS Keychain.
- Inline GitHub PAT sign-in when no token is configured.

OAuth device flow, auto-updates, widgets, multi-account support, and extra PR tabs are deferred.

## Run

Build and launch the native menu bar app:

```sh
swift run VCDash
```

Without GitHub credentials, VC Dash shows an inline GitHub token form in the menu and does not display pull request data.

Build a local `.app` bundle with `LSUIElement`:

```sh
scripts/build-app-bundle.sh
open .build/VCDash.app
```

Update the locally installed app bundle and restart it:

```sh
scripts/update-installed-app.sh
```

By default this updates `/Applications/VC Dash.app` if present, then
`~/Applications/VC Dash.app` if present, otherwise it installs to
`~/Applications/VC Dash.app`. To update a specific bundle:

```sh
APP_PATH="/path/to/VC Dash.app" scripts/update-installed-app.sh
```

## Sign In With A Personal Access Token

1. Create a GitHub fine-grained personal access token.
2. Grant repository access for the repositories VC Dash should monitor.
3. Include read permissions for metadata, pull requests, issues, and actions where applicable.
4. Launch the app with `swift run VCDash`.
5. Open the status item menu.
6. Paste only the token value, for example `github_pat_...`, with no surrounding text.
7. Click **Connect**.

VC Dash validates the token by fetching the current GitHub user, stores it in Keychain, and then syncs PRs.

## Test

SwiftPM package validation:

```sh
swift test
```

Core behavior tests:

```sh
swift run VCDashCoreTestRunner
```

Build the app:

```sh
swift build --product VCDash
```
