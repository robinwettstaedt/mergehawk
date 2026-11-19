# MergeHawk Glossary

This project uses the terms below as its shared language for product work,
code review, agent tasks, and documentation. Prefer these terms when writing
issues, prompts, tests, UI copy, and implementation notes.

## Quick Reference

| Term | Meaning |
| --- | --- |
| In-app notification | A MergeHawk UI item shown in the app, currently in the `Notifications` tab. |
| PR notification history | MergeHawk-owned PR-related in-app notification rows shown in `Notifications`. |
| macOS local notification | A system notification delivered through macOS Notification Center. |
| Notification payload | The title/body/update metadata MergeHawk would send to macOS Notification Center. |
| PR / pull request | The app-level umbrella term for a provider-hosted code review/change request, including equivalent concepts from future version control platform integrations. |
| Ignored PR | A PR opened by a bot while "Ignore PRs opened by bots" is on, or by an account in "Ignored accounts". It leaves the lists and counts, creates no notifications, and its existing notification rows are hidden. |
| Hidden PR | A PR the user moved to the Hidden section with the manual per-PR Hide action. UI only: its notifications are unchanged. |
| Muted bot activity | Comments and reviews by bots on PRs the user still sees, muted by "Mute bot comment and review notifications". |
| Section | A collapsible group of PR cards under a heading in a PR tab (`Authored` or `Requested`). |
| Pinned section | The section at the top of a PR tab holding every pinned PR or stack, shown while it holds one. |
| Hidden section | The section at the bottom of a PR tab holding every hidden PR or stack, shown while it holds one, collapsed by default. |
| Active section | The `Authored` section for PRs that are neither pinned nor hidden, shown while Pinned or Hidden is shown. |
| Relationship section | A `Requested` section for the viewer's relationship to a PR: `Assigned`, `Direct` or a team section. Always shown. |
| Counted team | One of the viewer's teams turned on in Settings › Teams. Only review requests to counted teams count. |
| Team section | One `Requested` section per counted team, in Settings › Teams order. A PR goes under its most specific requested counted team. |
| Provider | The version control platform or service that supplies PRs and updates. |
| Update | A provider-derived change MergeHawk notices for a PR, such as a new comment, review, failed CI, or requested changes. |
| Complete PR refresh | One provider read attempt that discovers relevant PRs, fetches their complete paginated activity, reconciles disappeared PRs, and commits one coherent app state. |
| Sources refresh | A separate repository catalog and GitHub App installation refresh used by the `Sources` settings pane. |
| GitHub API budget | GitHub's hourly GraphQL points, shared by every tool acting as the user. |
| Reserve | The 20% of the GitHub API budget that automatic refreshes leave alone. |
| Pacing | How automatic refreshes run against the GitHub API budget: normal, stretched, or paused. |
| Mock mode | Fixture-backed app mode without real provider credentials, provider network calls, or macOS credential prompts. |
| Agent slot | A named isolated installed app bundle used for agent verification and native human review. |
| UI artifact | A generated visual verification file, usually a screenshot PNG. |

## Notification Terms

### In-App Notification

An app-owned notification item shown inside MergeHawk, currently in the
`Notifications` tab.

In-app notifications are derived from provider activity such as new comments,
new reviews, failed CI, or requested changes. They
are part of the app state and can be rendered, filtered, marked read or unread, and tested
without using macOS Notification Center.

Use this term when referring to:

- rows in the `Notifications` tab
- provider updates such as new comments or failed CI
- mock GitHub activity shown in the app UI
- notification preferences that affect which activity appears in the app

Avoid using plain "notification" when the distinction matters.

### PR Notification History

MergeHawk-owned PR-related in-app notification rows shown in `Notifications`.

PR notification history is derived from updates detected by MergeHawk, such as
new comments, new reviews, failed CI, or requested changes. Rows are retained
locally, can be marked read or unread, and should still open the original PR even if that
PR is no longer in the active dashboard list.

### macOS Local Notification

A system notification delivered through macOS Notification Center.

macOS local notifications are outside the app window/menu UI. They are useful
for alerting the user when MergeHawk is not open, but they are not the same thing
as in-app notifications.

Use this term when referring to:

- Notification Center delivery
- `UNUserNotificationCenter`
- system permission prompts
- banners, alerts, and sounds from macOS
- mock-mode JSONL records of would-have-posted system notifications

Avoid calling these "push notifications." MergeHawk is not currently receiving
remote push notifications from APNs.

### Notification Payload

The title/body/update metadata that MergeHawk would send to macOS Notification
Center.

In mock or agent mode, payloads can be recorded to JSONL artifacts instead of
being delivered as real macOS local notifications.

## PR Terms

### PR

The app-level term for a provider-hosted code review/change request.

Use `PR` and `pull request` as the umbrella terms for the thing MergeHawk tracks
in its dashboard. Today that maps to GitHub pull requests. In future provider
integrations, it also means the provider's equivalent code review/change request
concept, even if that platform uses a different native term.

Examples:

- "The dashboard lists PRs that need attention."
- "Sort PRs by created date."
- "The source fetches PRs from GitHub today and may fetch equivalent items from
  other version control platforms later."

When writing product docs, agent prompts, UI copy, tests, or task summaries,
prefer `PR` or `pull request` unless a provider-native API term is required for
accuracy.

### Ignored PR

A PR MergeHawk leaves out because of who opened it: a GitHub bot while "Ignore
PRs opened by bots" is on, or an account in "Ignored accounts" (both in
Settings › Sources). Ignoring is by author only. An ignored PR is not in the
Authored or Requested lists, in any of their sections (Pinned and Hidden
included), or in their counts, and it creates no in-app or macOS local
notifications. Its existing notification rows
are hidden until the ignore is lifted. Ignoring overrides the per-repository
Sources checkboxes, and it keeps the PR's pinned and hidden state.

Do not confuse it with a **Hidden PR**, which the user hides by hand and which
still notifies, or with **muted bot activity**, which mutes bot comments and
reviews on PRs the user still sees. "Hide archived repositories" and turned-off
review teams also remove PRs and notifications, but they are separate filters,
not ignoring.

### Section

A collapsible group of PR cards under a heading in a PR tab. The heading shows
the section's title, its count of cards (a stack card counts once), and the
column legend while expanded. Clicking a heading collapses or expands its
section, and Option-clicking it does the same for every section in the tab.
Collapse state lives in memory per tab: every section starts expanded except
Hidden.

A PR or stack sits in exactly one section. The PR filter only removes cards
inside a section: it never adds or removes a heading and never moves a card to
another section.

### Pinned Section

The first section of a PR tab, holding every pinned PR or stack whatever its
relationship. Shown while the tab has at least one pinned item with the filter
set to `All`, and then kept with a count of 0 under any filter.

### Hidden Section

The last section of a PR tab, holding every hidden PR or stack. A stack is
hidden when every open member is hidden. Shown while the tab has at least one
hidden item with the filter set to `All`, and collapsed by default.

### Active Section

The `Authored` section for own PRs that are neither pinned nor hidden. Shown
only while the Pinned or Hidden section is shown, even with 0 cards. Without
them, `Authored` is a plain list under the column header with no heading.

### Relationship Section

A `Requested` section for how the viewer is asked to review: `Assigned`,
`Direct` or one of the team sections. Always shown, even with 0 cards. An item
that is neither pinned nor hidden goes to the first of Assigned, Direct and
Team that one of its open members belongs to, and within Team to its team
section.

### Counted Team

One of the viewer's GitHub teams that is turned on in Settings › Teams. A team
review request counts, and brings a PR into `Requested`, only when it names a
counted team. Turning a team off never turns its parent or child teams off.

### Team Section

One `Requested` section per counted team, shown even with 0 cards, in the
Settings › Teams order: organizations in order, top-level teams by slug, each
team followed by its child teams. The heading shows the team slug, or
`org/slug` when two counted teams share a slug, and its accessibility label
uses `@org/slug`.

A PR requesting several counted teams appears once. Of its requested counted
teams, any team that is an ancestor of another one is set aside (the viewer's
full team tree decides, turned-off teams included), and the PR goes under the
first remaining team in Settings order, so the most specific team wins. A stack
uses the counted teams requested by its open members that are in Team.

## Provider Terms

### Provider

The version control platform or service that supplies PRs and updates.

Current provider:

- GitHub

Possible future providers include other version control platforms.

Provider-specific words are correct when talking about provider integration
boundaries, API fields, or external documentation. Use `PR` or `pull request` in
shared app concepts unless the provider-specific distinction is the point.

## Update Terms

### Update

A provider-derived change that MergeHawk notices for a PR.

Examples:

- a new comment
- a new review
- failed CI
- requested changes

Updates are the underlying facts that can create in-app notifications and macOS
local notification payloads. In code, some of this is currently represented by
`PullRequestEvent`.

Prefer `update` in product language and agent tasks. Use `event` when referring
to the current code model or event-detection implementation.

### Complete PR Refresh

A provider read attempt that discovers all relevant PRs, hydrates complete
paginated activity, checks PRs that disappeared from discovery, and prepares one
coherent dashboard/history/activity state. The app publishes that state only after
the full attempt and its persistence succeed. Loading and errors may change while
the prior rows and notification history remain visible.

### Sources Refresh

A repository catalog and GitHub App installation refresh used by the `Sources`
settings pane. It is scheduled separately from a complete PR refresh, has its own
loading/error state, and does not gate dashboard publication.

## Budget Terms

### GitHub API Budget

GitHub's hourly GraphQL rate limit for the signed-in user, counted in points
(5,000 per hour). It is shared by every tool acting as that user: MergeHawk, `gh`,
coding agents, and IDE plugins. MergeHawk reads it from the `x-ratelimit-*`
headers of its GraphQL responses and shows it in Settings › General. The REST
budget is a separate bucket and is not part of it.

### Reserve

The 20% of the GitHub API budget that automatic refreshes leave alone, so `gh`
and other tools keep working. Manual refreshes may spend it.

### Pacing

How automatic complete PR refreshes run against the GitHub API budget:

- normal: refresh at the user's interval
- stretched: refresh at a longer interval until the budget resets
- paused: no automatic refresh until the budget resets

Settings and the menu refresh button show stretched and paused pacing.

## Agent Workflow Terms

### Mock Mode

An app launch mode that uses fixture data instead of real provider credentials
or network calls.

Mock mode should:

- avoid reading a GitHub personal access token
- avoid GitHub network calls
- avoid macOS credential prompts
- show fixture PRs and in-app notifications
- suppress real macOS local notification delivery
- optionally record macOS local notification payloads to artifacts
- offer deterministic delayed, failed, final-activity, and quiet-retirement refresh scenarios
- report a fixture GitHub API budget, with scenarios for normal, stretched, and paused pacing

### Agent Slot

A named, isolated installed app bundle used for agent verification and human
review.

Examples:

```sh
# Default Settings verification surface for agent testing.
scripts/run-agent-app.sh --slot agent-3 --mock --open
# Native handoff for a run verified with long-lists and notification type fixtures.
scripts/run-agent-app.sh --slot agent-3 --run-dir "$RUN_DIR" --stage app-review --ui native --mock --mock-scenario long-lists --notification-type-fixtures --open
```

Verification surfaces (`settings` and `menu`) are explicit agent testing aids.
Native presentation opens no Settings or persistent Verification Menu automatically.
The presentation choice is independent of mock fixture data. For same-run native
handoff, preserve the recorded `--mock-scenario` and replay
`--notification-type-fixtures` when the packaged verified bundle used it. Each
additional launch within a run needs an unused stage name, such as `app-review-2`
for a second native review launch; source changes require a fresh run.

An agent slot should have its own app name, bundle identifier, executable name,
and artifact directory so multiple agents can work in parallel without replacing
the user's normal app bundle.

### UI Artifact

A generated file used for visual verification, usually a screenshot PNG.

Agents should use UI artifacts to inspect mocked app states without requiring
manual screenshots from the user.
