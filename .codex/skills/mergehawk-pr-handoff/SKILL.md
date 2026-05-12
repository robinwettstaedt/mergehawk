---
name: mergehawk-pr-handoff
description: Use after user approval of verified MergeHawk issue work to prepare commits, push the branch, open or update a GitHub pull request, attach review evidence, close the issue app slot, and move the Linear issue to In Review.
---

# MergeHawk PR Handoff

Use this only after the user approves verified work for PR handoff, or when the user explicitly asks to create or update a PR for a MergeHawk issue.

## Hard Gate

Do not merge pull requests, enable auto-merge, or push directly to default/protected branches unless the user explicitly confirms that action in the current turn. Normal handoff stops after sharing the PR link and validation summary.

## Preflight

1. Confirm the issue identifier, branch name, and current git branch.
2. Confirm verification has run and collect the validation summary from `mergehawk-verification`.
3. Run `git status --short` and review all changed files before staging. Do not stage unrelated user changes.
4. Ensure generated screenshots and local verification artifacts are not committed unless the user explicitly asked for versioned fixtures.
5. If the branch has not been pushed, push it with `git push -u origin <branch>`.

## Commit Guidance

Use a concise semantic commit when committing remaining work, with the Linear issue identifier as scope when appropriate:

```text
feat(MER-12): add something to the app
fix(MER-12): correct notification filtering
chore(MER-12): update verification tooling
```

Commit only files required for the issue. Leave `.verification/`, `.build/`, and other generated local artifacts untracked.

## Pull Request

Use `gh` for GitHub actions.

Open or update a PR targeting `main`. Use a semantic PR title with the Linear issue identifier as the scope:

```text
feat(MER-12): add something to the app
```

Include in the PR body:

- concise implementation summary
- Linear issue identifier
- validation commands and results
- UI artifact paths or screenshots when they helped verify the change
- blocked or skipped verification, if any

If screenshots are useful for PR review, attach them to the PR body or a PR comment when possible. Do not rely on `.verification/<ISSUE-ID>/` paths as durable PR evidence; those paths are local to the current worktree and may disappear when the worktree is removed. If attachment is not possible, mention that local screenshots were captured but are not included in the PR. Do not commit generated screenshots by default.

## App Slot Cleanup

In the same turn as PR creation, close the isolated slot app by default. For `MER-12`, close:

```text
VC Dash MER-12.app
```

Do not remove worktrees or local artifacts unless the user explicitly asks.

## Linear Handoff

After the PR is created or updated successfully, move the Linear issue from `In Progress` to `In Review`. Leave the final move to `Done` for the human reviewer after review or merge.

Do not create routine Linear workpad comments. Use Linear comments only when the user asks or when a blocker needs to be recorded outside the Codex thread.

## Output

Report:

```md
## PR Handoff Summary

PR:
Branch:
Commit(s):
Linear issue:
Validation:
Review artifacts:
Slot app closed:
Linear state:
Merge status: ready for human review; not merged
```
