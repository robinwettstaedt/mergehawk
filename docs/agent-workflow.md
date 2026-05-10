# Agent Workflow

This document describes how coding agents should verify VC Dash changes without
replacing the user's normal installed app or requiring real GitHub credentials.

Read [docs/glossary.md](glossary.md) before changing product wording. In
particular, distinguish in-app notifications from macOS local notifications.

## Git Worktrees

Parallel agents should work from separate git worktrees so they do not change
the same checkout or interrupt the user's local workspace.

Use a branch name with the `codex/` prefix unless the user asks for a different
branch name.

Recommended layout:

```text
.worktrees/<branch-name>
```

Before creating a project-local worktree directory, verify that it is ignored by
git. If `.worktrees/` is not ignored yet, add it to `.gitignore` before creating
worktrees.

Example:

```sh
git check-ignore -q .worktrees || printf '\n.worktrees/\n' >> .gitignore
git worktree add .worktrees/codex/example-task -b codex/example-task
```

After creating a worktree, run the default verification from inside that
worktree before implementing substantial changes:

```sh
cd .worktrees/codex/example-task
scripts/verify.sh
```

Each worktree should use its own agent slot if it needs an installed app bundle.
Use a slot name that matches the task or branch, for example:

```sh
scripts/run-agent-app.sh --slot example-task --mock --no-open
```

Do not run `scripts/update-installed-app.sh` from parallel worktrees unless the
user explicitly asks for a final installed-app integration check.

## Default Verification

For most code changes, run:

```sh
scripts/verify.sh
```

This runs:

- `swift test`
- `swift run VCDashCoreTestRunner`
- `swift build --product VCDash`
- `.app` bundle creation through `scripts/build-app-bundle.sh`

`scripts/verify.sh` does not replace or launch the user's normal installed app.

## Visual Verification

For UI changes, run:

```sh
scripts/verify-ui.sh
```

This renders mocked menu states to:

```text
.build/verification/ui
```

Current artifacts include:

- `menu-notifications.png`
- `menu-my-prs.png`

Agents should inspect these screenshots when changing menu layout, copy, colors,
spacing, filtering, sorting, or in-app notification presentation.

## Mock Mode

Mock mode starts the app with fixture data instead of real provider credentials
or network calls.

Mock mode:

- starts signed in as `agent-fixture`
- avoids reading a GitHub personal access token
- avoids GitHub network calls
- avoids macOS credential prompts
- shows fixture PRs
- shows fixture in-app notifications
- suppresses real macOS local notification delivery
- can record would-have-posted macOS local notification payloads to JSONL

Run mock mode directly with:

```sh
VC_DASH_MOCK_MODE=1 swift run VCDash --mock
```

## Agent Slots

When an agent needs an installed `.app` bundle, use an agent slot instead of
`scripts/update-installed-app.sh`.

Example:

```sh
scripts/run-agent-app.sh --slot agent-3 --mock --open
```

To build and install the slot bundle without opening it:

```sh
scripts/run-agent-app.sh --slot agent-3 --mock --no-open
```

For `agent-3`, this installs:

```text
~/Applications/VC Dash agent-3.app
```

The slot bundle uses:

- app name: `VC Dash agent-3.app`
- bundle id: `com.vcdash.app.agent-3`
- executable name: `VCDash-agent-3`
- artifact directory: `.build/agent-slots/agent-3`

This lets multiple agents work from different checkouts without replacing the
normal app bundle or killing the normal `VCDash` process.

## macOS Local Notification Payload Artifacts

Mock slot runs suppress real macOS local notification delivery. They still
exercise the formatting path and record payloads to:

```text
.build/agent-slots/<slot>/notifications.jsonl
```

Use this artifact to verify macOS local notification titles, bodies, event
types, PR ids, PR titles, and repositories.

This is separate from in-app notifications, which are rendered in the app UI and
covered by `scripts/verify-ui.sh`.

## Final Local App Update

The normal installed app update is reserved for final local integration checks.
After making code changes that affect the local macOS app and after verification
passes, run:

```sh
scripts/update-installed-app.sh
```

This rebuilds, replaces, and reopens the user's normal installed app bundle.
