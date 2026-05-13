---
name: mergehawk-pr-handoff
description: Use after user approval of verified MergeHawk issue work to prepare commits, push the branch, open or update a GitHub pull request, attach review evidence, tear down the issue app slot, and move the Linear issue to In Review.
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
- blocked or skipped verification, if any

Only include review evidence that will remain accessible to future PR readers.
Attach screenshots to the PR body or a PR comment when they are useful for
review. Do not mention local-only paths such as `.verification/<ISSUE-ID>/`,
`.build/`, local app slots, or local slot cleanup in the PR body. Do not commit
generated screenshots by default.

## App Slot Teardown

In the same turn as PR creation or update, tear down the isolated slot app by
default. For `MER-12`, run:

```sh
scripts/teardown-agent-app.sh --slot MER-12
```

This quits the slot app, removes `~/Applications/MergeHawk MER-12.app`, and
removes `.build/agent-slots/MER-12/`. Report any teardown failure explicitly.

Do not remove worktrees, `.verification/<ISSUE-ID>/`, or other review artifacts
unless the user explicitly asks.

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
Slot app removed:
Linear state:
Merge status: ready for human review; not merged
```

The handoff summary is the right place for local operational details such as
slot teardown, local artifact paths, and cleanup status. Keep those details out
of the durable GitHub PR description unless they describe a user-facing or
reviewable code change.
