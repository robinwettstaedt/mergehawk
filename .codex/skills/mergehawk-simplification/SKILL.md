---
name: mergehawk-simplification
description: Use after implementing or modifying MergeHawk code, before mergehawk-review, to simplify recently changed code while preserving behavior and removing speculative fallbacks, backwards compatibility, defensive guards, or abstractions that are not required by the current issue.
---

# MergeHawk Simplification

Use this after implementation and before `mergehawk-review`. It may also be used after a meaningful implementation slice when the diff is starting to look complex.

## Goal

Refine recently changed code so it is direct, readable, consistent with the codebase, and no more defensive or abstract than the current issue requires. Preserve behavior exactly.

## Scope

Focus on code changed in the current session, usually from:

```sh
git diff
```

Do not broaden into unrelated refactors. Do not change public behavior, product decisions, or acceptance criteria from the approved plan.

## Greenfield Rule

Treat MergeHawk as a greenfield project. Remove or avoid speculative complexity unless it is required by the issue, existing behavior, or a concrete current failure mode.

Look especially for unnecessary:

- fallbacks or fallback UI states
- backwards-compatibility paths
- migration layers
- broad defensive guards for impossible states
- retries, recovery paths, or error handling added just in case
- configuration switches or feature flags not requested by the issue
- wrappers around one caller
- abstractions before there are at least two real use cases
- comments that restate obvious code

If a guard, fallback, or abstraction seems necessary, it should map to a real requirement, observed failure, or existing behavior. Otherwise simplify it away.

## Refinement Checklist

Review the diff for opportunities to:

- flatten unnecessary nesting
- remove duplicate branches or repeated logic
- improve names so code needs fewer comments
- keep functions/components focused on one responsibility
- prefer explicit, readable code over clever compact code
- keep useful boundaries and do not collapse separate concerns into dense one-liners
- align with existing local Swift/macOS patterns
- remove temporary scaffolding left over from implementation

## Verification Impact

If simplification changes code, run the lightest relevant focused check before continuing. Independent review belongs to `mergehawk-review`.

## Output

Report only meaningful simplifications:

```md
## Simplification Summary

Changed:
Removed complexity:
Behavior preserved:
Focused checks run:
Next: mergehawk-review
```

If no simplification is needed, say so briefly and proceed to `mergehawk-review`.
