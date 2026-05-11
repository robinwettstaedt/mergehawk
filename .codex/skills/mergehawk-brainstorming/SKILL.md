---
name: mergehawk-brainstorming
description: Use after mergehawk-issue-intake for most MergeHawk Linear issues to clarify product intent, UX, copy, scope, tradeoffs, and acceptance criteria before planning or implementation.
---

# MergeHawk Brainstorming

Use this after issue intake to turn a Linear issue into an approved direction before planning or implementation.

## Hard Gate

Do not edit code, scaffold files, run implementation commands, or invoke implementation/verification/PR handoff skills during brainstorming. This skill should be run with the plan mode activated. Proceed to `mergehawk-planning` only after presenting a design direction and getting user approval.

Skip this skill only when the issue is tiny/mechanical or already contains a concrete approved plan with no unresolved product, UX, scope, or implementation questions.

## Process

1. Explore enough project context to avoid asking questions the repo can answer. Check relevant docs, nearby files, and recent context as needed. If the issue touches product wording, concepts, notifications, PRs/issues terminology, onboarding, or user-facing labels, consult `docs/glossary.md`.
2. Restate the issue in plain language: what problem appears to be solved and what outcome the user likely wants.
3. Check scope. If the issue spans multiple independent changes, recommend a smaller first slice before refining details.
4. Ask clarifying questions one at a time. Prefer multiple-choice questions when the tradeoff is clear. Focus on purpose, constraints, UX, copy, edge cases, success criteria, and out-of-scope boundaries.
5. Once intent is clear, propose 2-3 viable approaches with tradeoffs. Lead with the recommended approach and explain why.
6. Present a concise design direction scaled to the issue complexity. For small issues this can be a few bullets; for nuanced issues include behavior, UI/copy, data flow, error handling, and testing expectations.
7. Ask the user to approve or revise the design direction. If they request changes, revise and ask again.
8. After approval, output a short brainstorming summary and route to `mergehawk-planning`.

## Question Style

- Ask one question per message unless a small grouped set is clearly easier to answer.
- Prefer to use the integrated tooling (request_user_input / AskUserQuestion) for providing the user with a UI to answer questions.
- Do not ask questions that can be answered by inspecting the repo or Linear issue context.
- Use concrete options with a recommended default when possible.
- Keep the conversation focused on decisions that affect the implementation.

## Design Quality

Design for small, clear units with understandable boundaries. Follow existing codebase patterns and include targeted cleanup only when it directly supports the issue. Do not propose unrelated refactors.

For UI or product behavior, clarify what the user should see, what should stay unchanged, and what verification evidence will matter later.

## Output

When the user approves the design direction, provide:

```md
## Brainstorming Summary

Goal:
Decisions:
Chosen approach:
Acceptance criteria:
Out of scope:
Risks or assumptions:
Next: mergehawk-planning
```
