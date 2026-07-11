---
name: mergehawk-implementation
description: Use after approval of a MergeHawk implementation plan to have the required repo-scoped Terra subagent implement and test the work while the main agent remains the orchestrator.
---

# MergeHawk Implementation

Use this after the user approves the `mergehawk-planning` output.

## Hard Gate

The main agent must not edit implementation files. Spawn one subagent using the repo-scoped `terra` agent type configured in `.codex/agents/terra.toml`. Do not use a generic or differently configured subagent. If Terra is unavailable, stop and report the blocker.

## Orchestrator Handoff

Give the Terra implementer a decision-complete work packet containing:

- issue id, goal, and acceptance criteria
- approved direction and implementation plan
- branch, worktree, slot, and artifact paths
- relevant repository instructions and glossary requirements
- known file/component scope and unrelated changes to preserve
- verification commands and expected UI/runtime evidence

Ask the implementer to inspect the repository and current diff itself before editing. The implementer owns implementation, tests, focused checks, and behavior-preserving simplification. It must not broaden product scope or overturn approved decisions. It should report unexpected plan conflicts to the main agent instead of deciding materially different behavior itself.

## Implementation Loop

Keep the Terra implementer available after its first pass. The main agent:

1. inspects the resulting diff and check results
2. invokes `mergehawk-review` with two independent Terra reviewers
3. evaluates every finding itself
4. sends accepted findings and exact requested changes back to the original implementer
5. inspects the new diff and requests targeted rechecks when required

If the original implementer is unavailable, spawn a replacement using the `terra` agent type and provide the full work packet, current diff context, check results, and accepted findings.

The main agent must not apply review fixes itself. If verification later exposes a required code or documentation change, route it through the same Terra implementer loop.

## Implementer Output

Request a concise report containing:

```md
## Implementation Summary

Changed:
Plan deviations or questions:
Tests and focused checks:
Simplification performed:
Known limitations or remaining work:
Ready for independent review: yes/no
```

Proceed to `mergehawk-review` only when the implementation is coherent and focused checks have passed or any failures are clearly understood.
