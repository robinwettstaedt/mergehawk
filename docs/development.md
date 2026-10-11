# Development

Building, running and testing MergeHawk from source. Shared project terminology lives in
[glossary.md](glossary.md).

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
11. Use this organization permission:
    - Members: Read-only

    MergeHawk needs it to read your teams for per-team review request filtering.
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
   A fine-grained token also needs the organization permission **Members: Read-only** so
   MergeHawk can read your teams; a classic token's `read:org` scope already covers it.
4. Launch the app with `swift run mergehawk`.
5. Open Settings, then the Auth pane.
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

Isolated mock launches default to the Settings verification surface for unattended
agent testing:

```sh
scripts/run-agent-app.sh --slot local --mock --open
```

The explicit `--ui settings` and `--ui menu` verification surfaces are agent testing
aids. Human review uses `--ui native`, which starts the normal menu bar app without
automatically opening Settings or a persistent Verification Menu. Presentation is
independent of fixture data: all three choices keep the slot in mock mode with
isolated app identity and suppressed macOS local notifications.

Isolated mock launches support deterministic complete-refresh scenarios:

```sh
scripts/run-agent-app.sh --slot local --mock --mock-scenario delayed-refresh --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario refresh-failure --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario merged-final-activity --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario quiet-access-loss --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario bot-notifications --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario comment-notifications --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario long-lists --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario review-teams --ui menu --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario budget-stretched --ui settings --open
scripts/run-agent-app.sh --slot local --mock --mock-scenario budget-paused --ui settings --open
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
The `review-teams` scenario has nested teams (`engineering` → `developers` →
`plm-team`, with the viewer directly in `plm-team`) and pull requests requesting
each of them, a team the viewer is not in, and combinations. Turn teams off in
Settings › Teams to see the Requested tab change; the first refresh adds
`plm-team` to the pull request that only requested `developers`.
Every scenario reports a fixture GitHub API budget of 5,000 points that resets
50 minutes after launch, and each complete refresh spends 55 points. The
`budget-stretched` and `budget-paused` scenarios start with less of it left, so
after the first refresh pacing becomes stretched or paused (a manual refresh still
works). The budget shows in Settings › General and in the menu refresh button.

When reusing one verification run, give each additional launch a unique `--stage`
such as `app-final-activity`. This keeps its app log and mock notification JSONL
immutable while the default first launch remains the `app` stage.

For human review of the same verified source and bundle, reuse the printed run
directory and slot with a native review stage. Preserve the recorded
`--mock-scenario` and replay `--notification-type-fixtures` when the packaged
verified bundle used it. For example, a run verified with the `long-lists`
scenario and notification type fixtures uses this matching handoff:

```sh
scripts/run-agent-app.sh --slot local --run-dir "$RUN_DIR" --stage app-review --ui native --mock --mock-scenario long-lists --notification-type-fixtures --open
```

This replaces the slot's running process while preserving its packaged app and
prior verification evidence. Record the exact review stage name for validation;
use an unused suffix such as `app-review-2` for another same-source launch. Source
changes require a fresh verification run. Open Settings from the native menu or
with Command-comma; explicit Settings actions bring its shared window forward.
