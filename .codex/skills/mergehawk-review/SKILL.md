---
name: mergehawk-review
description: Use after implementing and simplifying MergeHawk issue work, before final verification, to request independent subagent review for plan adherence and code quality, then triage findings before continuing.
---

# MergeHawk Review

Use this after `mergehawk-simplification` and before final `mergehawk-verification`. It may also be used after a large or risky implementation slice once focused checks have made the work coherent enough to review.

## Goal

Catch issues before final verification by asking independent reviewers to inspect the completed candidate diff. Keep review scoped to the current Linear issue, approved plan, and changed code.

## Before Requesting Review

Confirm the work is ready for review:

- implementation is coherent, not half-finished
- relevant focused checks have run when practical
- `mergehawk-simplification` has already been used
- `git diff` reflects only intended issue work, or unrelated changes are clearly excluded from reviewer scope

Use compact work-product context. Do not rely on subagents having the full conversation history, and do not ask them to trust a summary instead of inspecting the repo.

## Reviewers

Spawn two independent subagents when subagent tools are available.

### Spec Reviewer

Give the reviewer the issue id, product context, approved direction, and implementation plan. Ask the reviewer to inspect the repo and check whether the implementation matches:

- Linear issue goal and acceptance criteria
- approved brainstorming direction
- implementation plan
- expected user-facing behavior, copy, UI state, and artifacts

The reviewer should identify missing behavior, unjustified plan deviations, over-scoped work, and plan problems discovered during implementation.

### Code Reviewer

Give the reviewer the issue id, a one-sentence intent, technical constraints, and checks already run. Keep product context minimal so the review focuses on what the code change actually does. Ask the reviewer to inspect the repo and review for:

- correctness bugs and regressions
- security, privacy, data-loss, or reliability risks
- code quality and maintainability
- unnecessary complexity under the MergeHawk greenfield rule
- test gaps that matter for the changed behavior
- consistency with existing project patterns

## Reviewer Context

Give both reviewers enough orientation to find the work, then ask them to inspect `git status`, `git diff`, relevant files, and tests themselves.

Provide:

- branch or base context, if relevant
- changed file list or diff scope
- focused checks already run and their results
- UI artifacts or screenshot paths when relevant

## Triage Findings

The main agent owns judgment. Reviewer feedback is not automatically correct.

For every actionable finding, choose one outcome:

- `fixed`: implement the change and run the lightest relevant check
- `rejected`: explain why the finding is not correct for this codebase or issue
- `deferred`: report it as valid but outside the current scope, and suggest follow-up only when useful

Fix blocking correctness, security, data-loss, and clear spec misses before final verification unless the user explicitly decides otherwise.

If a finding conflicts with the approved direction or would materially expand scope, stop and ask the user before implementing it.

## Recheck Loop

Run one targeted recheck when fixes address blocking or important findings, or when the fixes materially change the diff.

Prefer asking the original reviewer to verify only:

- whether the addressed findings were fixed correctly
- whether rejected or deferred findings have a sound rationale
- whether the fix introduced obvious new issues

Do not run an open-ended review loop by default. If a recheck still finds substantial issues, fix once more when the path is clear; otherwise report the remaining decision or scope question to the user.

## Output

Report:

```md
## Review Summary

Reviewers:
Spec findings:
Code findings:
Fixed:
Rejected:
Deferred or reported:
Focused checks run after fixes:
Recheck:
Next: mergehawk-verification
```
