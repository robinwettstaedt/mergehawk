# vc-dash agent instructions

- Follow the agent workflow in `docs/agent-workflow.md` for verification, mock mode, isolated app slots, UI artifacts, and notification payload artifacts.
- Use the shared vocabulary in `docs/glossary.md` when discussing product behavior with the user, writing docs, naming tests, or creating agent task summaries.
- Use git worktrees for parallel agent implementation work; see `docs/agent-workflow.md`.
- Do not run `scripts/update-installed-app.sh` as part of normal agent verification. Use `scripts/verify.sh`, `scripts/verify-ui.sh`, and isolated agent slots instead.
- Run `scripts/update-installed-app.sh` only when explicitly asked to perform the final local installed-app integration check.
- When performing GitHub actions, use the `gh` CLI.
