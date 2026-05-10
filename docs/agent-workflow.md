# Agent Workflow

This document describes how coding agents should verify VC Dash changes without
replacing the user's normal installed app or requiring real GitHub credentials.

Read [docs/glossary.md](glossary.md) before changing product wording. In
particular, distinguish in-app notifications from macOS local notifications.

## Isolated Agent Workspaces

Parallel agents should work from isolated git worktrees so they do not change
the same checkout or interrupt the user's local workspace.

Before implementation work, check whether the current checkout is already a
linked worktree:

```sh
git_dir="$(git rev-parse --path-format=absolute --git-dir)"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
if [ "$git_dir" != "$common_dir" ]; then
  echo "already in linked worktree"
else
  echo "primary checkout; create or switch to an isolated worktree before editing"
fi
```

If the agent is already in a linked worktree, use that checkout directly and do
not create another worktree. If the agent is in the primary checkout, create or
switch to an isolated worktree before editing unless the user explicitly asks to
work in the primary checkout.

Before editing, require a clean starting point:

```sh
git status --short
```

If the worktree contains uncommitted changes that are not part of the current
task, stop and ask the user how to proceed.

Base new isolated worktrees on `origin/main` unless the user specifies a
different base branch or commit. For Linear issues, start the branch name with
the issue identifier, for example:

```text
MER-12-update-something-in-the-app
```

Recommended local fallback layout:

```text
.worktrees/<branch-name>
```

Example:

```sh
git fetch origin main
git worktree add .worktrees/MER-12-update-something -b MER-12-update-something origin/main
cd .worktrees/MER-12-update-something
scripts/verify.sh
```

Each parallel agent should use its own agent slot if it needs an installed app
bundle. For Linear issues, use the issue identifier as the slot name:

```sh
scripts/run-agent-app.sh --slot MER-12 --mock --no-open
```

Do not run `scripts/update-installed-app.sh` from parallel agent workspaces
unless the user explicitly asks for a final installed-app integration check.
Build output, verification screenshots, and `.verification/` review evidence
are local to the worktree where the agent runs.

## Linear Issue Workflow

When the user asks an agent to work on a Linear issue:

1. Fetch and read the requested issue before implementation.
2. Ask clarifying questions before editing when the scope, acceptance criteria,
   or desired product behavior is ambiguous.
3. Confirm the checkout/worktree state described above.
4. Move the Linear issue to `In Progress` when implementation begins.
5. Implement the issue in the isolated worktree.
6. Self-verify with the relevant checks in this document until the work is ready
   for user review.
7. Report the change, validation results, and any review artifacts back to the
   user.
8. Wait for user approval before opening a pull request unless the user has
   already explicitly asked for a PR.

For UI-heavy changes, leave the isolated mocked app slot open when useful and
tell the user which slot app to review. Do not create routine Linear workpad
comments; use Linear comments only when the user asks, or when a blocker needs
to be recorded outside the Codex thread.

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

## Interactive UI Verification

Use interactive UI verification when static screenshot artifacts are
insufficient, especially for changes involving app launch behavior, navigation,
menu interactions, window state, permissions, timers, refresh behavior, or other
runtime-only UI states.

Run an isolated mocked app slot:

```sh
scripts/run-agent-app.sh --slot MER-12 --mock --open
```

Then use the available screen inspection or screenshot tools to verify the
running app. Prefer Codex computer-use tools when available. Record the
verification signal in the task summary, including what was opened, what state
was inspected, and any relevant screenshot artifact path when one was captured.
Place ad hoc screenshots and review evidence under an issue- or task-specific
directory in `.verification/`, for example:

```text
.verification/MER-12/
```

The slot app opens as a real macOS app on the user's machine, usually at:

```text
~/Applications/VC Dash <slot>.app
```

It is isolated by app name, bundle id, process name, mock-mode launch
environment, and agent-slot artifact directory. It is not hidden from the user.
When useful for review, leave the slot app open and state the exact app name in
the response.

If interactive verification is blocked because computer-use tools are
unavailable, the app does not launch, or screenshots cannot be captured, report
exactly what was skipped and why. When possible, leave the isolated slot app
open for the user to inspect manually.

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
scripts/run-agent-app.sh --slot MER-12 --mock --open
```

To build and install the slot bundle without opening it:

```sh
scripts/run-agent-app.sh --slot MER-12 --mock --no-open
```

For `MER-12`, this installs:

```text
~/Applications/VC Dash MER-12.app
```

The slot bundle uses:

- app name: `VC Dash MER-12.app`
- bundle id: `com.vcdash.app.MER-12`
- executable name: `VCDash-MER-12`
- artifact directory: `.build/agent-slots/MER-12`

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

## Pull Request Handoff

After the user approves the completed work, open a pull request with `gh` when
asked. Include:

- a concise summary of the implementation
- the Linear issue identifier
- validation commands and results
- relevant UI artifact paths or screenshots when they helped verify the change

Do not commit generated screenshots or local verification artifacts unless the
user explicitly asks for versioned fixtures. If screenshots are useful for PR
review, attach them to the PR body or a PR comment, or reference their local
artifact paths in the handoff summary. Put ad hoc PR-review screenshots under
`.verification/<issue-or-task>/` so they remain ignored by git.

Use semantic PR titles with the Linear issue identifier as the scope:

```text
feat(MER-12): add something to the app
fix(MER-12): correct notification filtering
chore(MER-12): update verification tooling
```

In the same turn as PR creation, close the isolated slot app by default. For a
slot named `MER-12`, close:

```text
VC Dash MER-12.app
```

Then move the Linear issue from `In Progress` to `In Review`. Leave the final
move to `Done` for the human reviewer after the PR is reviewed or merged.

## Final Local App Update

The normal installed app update is reserved for final local integration checks.
Only run this when the user explicitly asks to update the normal installed app.
After verification passes, run:

```sh
scripts/update-installed-app.sh
```

This rebuilds, replaces, and reopens the user's normal installed app bundle.
