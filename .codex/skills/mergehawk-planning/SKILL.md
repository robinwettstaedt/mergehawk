---
name: mergehawk-planning
description: Use after mergehawk-brainstorming or an already-approved MergeHawk issue direction to create a concrete implementation and verification plan before coding.
---

# MergeHawk Planning

Use this after the user approves a brainstorming direction, or when the Linear issue already contains a concrete approved plan.

## Hard Gate

Do not edit code, scaffold files, run implementation commands, or invoke implementation/verification/PR handoff skills during planning. Create a decision-complete plan first, then get user approval.

## Planning Inputs

Use the current issue context, approved brainstorming summary, user decisions, and relevant repo context. Inspect files/docs enough to make the plan specific. If the issue touches product wording, concepts, notifications, PRs/issues terminology, onboarding, or user-facing labels, consult `docs/glossary.md`.

## Required Planning Checks

Before writing the plan:

1. Confirm the issue identifier, branch naming root, app slot, and artifact directory:
   - Branch: `<ISSUE-ID>-<short-readable-title-slug>`
   - Slot: `<ISSUE-ID>`
   - Artifacts: `.verification/<ISSUE-ID>/`
2. Confirm the git context:
   - If already in a clean linked worktree, plan implementation there.
   - If in the primary checkout, include a pre-implementation decision: continue in primary checkout, restart in a prepared worktree, or explicitly have the agent create a worktree.
   - If uncommitted changes are present that are unrelated to the task, stop and ask before planning implementation steps that depend on them.
3. Check whether the approved direction is too broad for one implementation pass. If so, propose the smallest shippable slice and plan only that slice, but make sure to report that decision to the user.

## Plan Quality

- Follow existing codebase patterns.
- Keep the implementation small and shippable.
- Prefer focused changes over broad rewrites.
- Include targeted cleanup only when it directly supports the issue.
- Name exact files/components when known.
- Include exact commands for verification.
- Include UI verification expectations when UI, copy, layout, menu behavior, app launch, timers, refresh behavior, or runtime state changes are involved.
- Avoid placeholders such as `TBD`, `TODO`, `add tests as needed`, or `handle edge cases` without specifics.

## Output Format

Produce the plan in the Codex thread. Do not save or commit a plan document unless the user explicitly asks.

```md
## Implementation Plan

Issue:
Branch:
Worktree:
Slot:
Artifact directory:

Goal:
Approved direction:
Files/components likely involved:
Implementation steps:
Verification plan:
UI review plan:
Risks or assumptions:
Next: implement, then use mergehawk-simplification
```

Scale the plan to the task. For small tasks, keep sections brief. For nuanced tasks, make each implementation step independently understandable and include enough detail that another agent could execute it without re-deciding the design.

## Approval Gate

After presenting the plan, ask the user to approve or revise it before implementation. If the user requests changes, revise the plan and ask again. 
