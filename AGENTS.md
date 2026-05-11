# vc-dash agent instructions

- For active MergeHawk Linear issue work, use the repo skills in `.codex/skills/` phase by phase: `mergehawk-issue-intake`, `mergehawk-brainstorming`, `mergehawk-planning`, `mergehawk-verification`, and `mergehawk-pr-handoff`.
- Use the shared vocabulary in `docs/glossary.md` when discussing product behavior with the user, writing docs, naming tests, or creating agent task summaries.
- Treat this as a greenfield project. Prefer direct, scoped implementations and do not add speculative fallbacks, backwards-compatibility paths, broad defensive guards, migration layers, or extra configuration unless the current issue or existing behavior clearly requires them.
- Do not run `scripts/update-installed-app.sh` as part of normal agent verification. Use `scripts/verify.sh`, `scripts/verify-ui.sh`, and isolated agent slots instead.
- Run `scripts/update-installed-app.sh` only when explicitly asked to perform the final local installed-app integration check.
- When performing GitHub actions, use the `gh` CLI.
