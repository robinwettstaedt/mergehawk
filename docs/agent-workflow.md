# Agent Workflow

This document is the source-of-truth reference for the MergeHawk agent workflow.
The operational instructions live in repo skills under `.codex/skills/`.

Read [docs/glossary.md](glossary.md) before changing product wording. In
particular, distinguish in-app notifications from macOS local notifications.

## Skill Sequence

For active MergeHawk Linear issue work, use these skills in order:

1. `mergehawk-issue-intake`
2. `mergehawk-brainstorming`
3. `mergehawk-planning`
4. implementation using normal Codex coding behavior and the approved plan
5. `mergehawk-simplification`
6. `mergehawk-verification`
7. `mergehawk-pr-handoff`

Implementation is intentionally not its own skill. Use normal codebase judgment,
the approved plan, and the repo instructions in `AGENTS.md`.

## Issue Intake

Use `mergehawk-issue-intake` when the user asks to work on a MergeHawk Linear
issue such as `MER-12`, including terse prompts that only mention the issue id.

The intake phase fetches the issue, confirms it belongs to MergeHawk, establishes
branch/slot/artifact naming, checks git/worktree state, moves active work to
`In Progress`, and routes to brainstorming by default.

Worktree policy:

- Prefer starting the Codex thread in the intended worktree so the Codex UI is
  attached to the right checkout from the beginning.
- If already in a clean linked worktree, use it directly.
- If in the primary checkout, do not automatically create a worktree. Before
  implementation, ask whether to continue there, restart in a prepared worktree,
  or explicitly have the agent create a worktree.
- If the user explicitly asks the agent to create a worktree, base it on
  `origin/main` unless the user specifies another base.

Naming:

- Branch: `<ISSUE-ID>-<short-readable-title-slug>`, for example
  `MER-12-update-settings-refresh`.
- App slot: `<ISSUE-ID>`, for example `MER-12`.
- Review artifacts: `.verification/<ISSUE-ID>/`.

## Brainstorming And Planning

Use `mergehawk-brainstorming` for most issues after intake. Skip it only when
the issue is tiny/mechanical or already contains a concrete approved plan with
no unresolved product, UX, scope, or implementation questions.

Brainstorming clarifies user intent, tradeoffs, UX/copy, scope, edge cases, and
acceptance criteria. It must not edit code. It ends with an approved design
direction and routes to `mergehawk-planning`.

Use `mergehawk-planning` to turn the approved direction into a concrete
implementation and verification plan before coding. Planning must not edit code.
It should name likely files/components, verification commands, UI review needs,
risks, and assumptions. After approval, implement normally, then run
`mergehawk-simplification` before final verification.

## Simplification

Use `mergehawk-simplification` after implementation and before final
verification. It reviews recently changed code, usually via `git diff`, and
preserves behavior while removing unnecessary complexity.

Treat MergeHawk as a greenfield project. Avoid speculative fallbacks,
backwards-compatibility paths, migration layers, broad defensive guards,
unrequested configuration, and premature abstractions unless required by the
issue, existing behavior, or a concrete current failure mode.

## Verification

Use `mergehawk-verification` during implementation after meaningful slices and
after implementation before telling the user the work is ready for review.

For most code changes, final verification includes:

```sh
scripts/verify.sh
```

This runs `swift test`, `swift run VCDashCoreTestRunner`,
`swift build --product VCDash`, and app bundle creation through
`scripts/build-app-bundle.sh`. It does not replace or launch the user's normal
installed app.

For UI, copy, menu layout, filtering, sorting, notification presentation, or
visual state changes, run:

```sh
scripts/verify-ui.sh
```

This renders mocked UI screenshots to `.build/verification/ui`.

When static screenshots are insufficient, run an isolated mocked app slot:

```sh
scripts/run-agent-app.sh --slot MER-12 --mock --open
```

Prefer Codex computer-use tools for interactive visual verification when
available. Put ad hoc screenshots and review evidence under
`.verification/<ISSUE-ID>/`. Leave the slot app open for user review when useful
and state the exact app name, usually `~/Applications/VC Dash <ISSUE-ID>.app`.

Do not run `scripts/update-installed-app.sh` as part of normal verification.
Only run it when the user explicitly asks for a final local installed-app
integration check.

## PR Handoff

Use `mergehawk-pr-handoff` only after the user approves verified work for PR
handoff, or when the user explicitly asks to create or update a PR.

Use `gh` for GitHub actions. Open or update a PR targeting `main` with a
semantic PR title scoped to the Linear issue:

```text
feat(MER-12): add something to the app
fix(MER-12): correct notification filtering
chore(MER-12): update verification tooling
```

Include the implementation summary, Linear issue id, validation results, and
review evidence. Do not commit generated screenshots or local verification
artifacts unless the user explicitly asks for versioned fixtures. Attach useful
screenshots to the PR body/comment when possible; `.verification/<ISSUE-ID>/`
paths are local-only and not durable PR evidence.

In the same turn as PR creation, close the isolated slot app by default. Then
move the Linear issue from `In Progress` to `In Review`. Leave `Done` for the
human reviewer after review or merge.

Never merge pull requests, enable auto-merge, or push directly to default or
protected branches unless the user explicitly confirms that action in the
current turn.
