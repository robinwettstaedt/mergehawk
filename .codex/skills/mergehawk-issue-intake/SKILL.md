---
name: mergehawk-issue-intake
description: Use first when the user asks to work on, start, pull, implement, or otherwise begin a MergeHawk Linear issue such as MER-12, including terse prompts that only mention an MER issue identifier.
---

# MergeHawk Issue Intake

Use this as the entrypoint for active work on a MergeHawk Linear issue.

## Intake Steps

1. Parse the issue identifier from the user request, for example `MER-12`.
2. Fetch the Linear issue and read its title, description, current state, labels, project, and relevant links or comments.
3. Assume `MER` issues belong to MergeHawk unless the fetched issue says otherwise. Warn before proceeding if the issue is not in the MergeHawk team/project.
4. If the user asked to work on, start, implement, or otherwise actively handle the issue, move it to `In Progress` after confirming the fetched issue is the intended one. Do not move state for read-only requests such as summarizing, inspecting, or explaining an issue.
5. Establish naming:
   - Branch: `<ISSUE-ID>-<short-readable-title-slug>`, for example `MER-12-update-settings-refresh`.
   - App slot: `<ISSUE-ID>`, for example `MER-12`.
   - Review artifacts: `.verification/<ISSUE-ID>/`, for example `.verification/MER-12/`.
6. Check the current git context before implementation:
   ```sh
   git_dir="$(git rev-parse --path-format=absolute --git-dir)"
   common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
   git status --short
   ```
7. If already in a linked worktree and the starting state is clean, use it directly. Do not create another worktree.
8. If in the primary checkout, do not automatically create a worktree. Before implementation, tell the user the thread is attached to the primary checkout and ask whether to continue there, restart in a prepared worktree, or explicitly have the agent create a worktree.
9. If the user explicitly asks the agent to create a worktree, base it on `origin/main` unless the user specifies another base.

## Routing

Use `mergehawk-brainstorming` next by default.

Skip brainstorming only when the issue is tiny/mechanical or already contains a concrete approved plan with no unresolved product, UX, scope, or implementation questions. If skipping brainstorming, state why and route directly to `mergehawk-planning`.

Do not handle detailed verification or PR handoff in this skill. Those belong to `mergehawk-verification` and `mergehawk-pr-handoff`.
