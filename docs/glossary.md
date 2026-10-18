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
| Provider | The version control platform or service that supplies PRs and updates. |
| Update | A provider-derived change MergeHawk notices for a PR, such as a new comment, review, failed CI, or requested changes. |
| Complete PR refresh | One provider read attempt that discovers relevant PRs, fetches their complete paginated activity, reconciles disappeared PRs, and commits one coherent app state. |
| Sources refresh | A separate repository catalog and GitHub App installation refresh used by the `Sources` settings pane. |
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
