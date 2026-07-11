# MergeHawk agent instructions

## Subagent Delegation

For active MergeHawk issue work, the main agent is the orchestrator. It owns issue intake, product clarification, the approved specification, implementation planning, reviewer prompts, review-feedback triage, and the final readiness decision. It must not implement or modify issue code itself.

Delegate all implementation and code-modification work to the repo-scoped `terra` agent type configured in `.codex/agents/terra.toml`. Keep the original Terra implementer for follow-up changes whenever it remains available. If it is unavailable, spawn a replacement Terra implementer with the complete approved plan, current diff context, checks, and accepted review findings.

Use the repo-scoped `terra` agent type for every MergeHawk subagent, including implementers, spec reviewers, code reviewers, and any delegated verification work. Do not silently substitute a generic or differently configured agent. If Terra cannot be started, stop before the delegated phase and report the blocker.

The main agent may inspect files and diffs, run read-only or verification commands, and evaluate results. Any resulting source, test, fixture, script, or documentation edits must go back to the Terra implementer.

- For active MergeHawk Linear issue work, use the repo skills in `.codex/skills/` phase by phase:
  1. `mergehawk-issue-intake`
  2. `mergehawk-brainstorming`, unless the issue is tiny/mechanical or already has a concrete approved direction
  3. `mergehawk-planning`, unless the user explicitly says to skip planning because the direction is already approved
  4. `mergehawk-implementation` to delegate the approved work to a Terra implementer
  5. run focused checks during implementation when useful
  6. `mergehawk-simplification`
  7. `mergehawk-review`
  8. triage reviewer feedback; send accepted changes back to the original Terra implementer and recheck as required
  9. `mergehawk-verification` for final verification
  10. stop for user review and approval
  11. `mergehawk-pr-handoff` only after user approval or an explicit PR handoff request

- Use the shared vocabulary in `docs/glossary.md` when discussing product behavior with the user, writing docs, naming tests, or creating agent task summaries.

- Treat this as a greenfield project. Prefer direct, scoped implementations and do not add speculative fallbacks, backwards-compatibility paths, broad defensive guards, migration layers, or extra configuration unless the current issue or existing behavior clearly requires them.

- Do not run `scripts/update-installed-app.sh` as part of normal agent verification. Use `scripts/verify.sh`, `scripts/verify-ui.sh`, and isolated agent slots instead.

- Run `scripts/update-installed-app.sh` only when explicitly asked to perform the final local installed-app integration check.

- When performing GitHub actions, use the `gh` CLI.
