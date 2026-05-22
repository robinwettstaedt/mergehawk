# MergeHawk agent instructions

- For active MergeHawk Linear issue work, use the repo skills in `.codex/skills/` phase by phase:
  1. `mergehawk-issue-intake`
  2. `mergehawk-brainstorming`, unless the issue is tiny/mechanical or already has a concrete approved direction
  3. `mergehawk-planning`, unless the user explicitly says to skip planning because the direction is already approved
  4. implement the approved work
  5. run focused checks during implementation when useful
  6. `mergehawk-simplification`
  7. `mergehawk-review`
  8. `mergehawk-verification` for final verification
  9. stop for user review and approval
  10. `mergehawk-pr-handoff` only after user approval or an explicit PR handoff request
- Use the shared vocabulary in `docs/glossary.md` when discussing product behavior with the user, writing docs, naming tests, or creating agent task summaries.
- Treat this as a greenfield project. Prefer direct, scoped implementations and do not add speculative fallbacks, backwards-compatibility paths, broad defensive guards, migration layers, or extra configuration unless the current issue or existing behavior clearly requires them.
- Do not run `scripts/update-installed-app.sh` as part of normal agent verification. Use `scripts/verify.sh`, `scripts/verify-ui.sh`, and isolated agent slots instead.
- Run `scripts/update-installed-app.sh` only when explicitly asked to perform the final local installed-app integration check.
- When performing GitHub actions, use the `gh` CLI.
