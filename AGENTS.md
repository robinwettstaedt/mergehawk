# vc-dash agent instructions

- Follow the agent workflow in `docs/agent-workflow.md` for verification, mock mode, isolated app slots, UI artifacts, and notification payload artifacts.
- Before implementation work, confirm whether the current checkout is already a linked git worktree. If it is, use it directly; if it is the primary checkout, create or switch to an isolated worktree based on `origin/main` unless the user specifies another base.
- Start Linear issue branch names with the issue identifier, for example `MER-12-update-something-in-the-app`.
- Use the shared vocabulary in `docs/glossary.md` when discussing product behavior with the user, writing docs, naming tests, or creating agent task summaries.
- Do not run `scripts/update-installed-app.sh` as part of normal agent verification. Use `scripts/verify.sh`, `scripts/verify-ui.sh`, and isolated agent slots instead.
- Run `scripts/update-installed-app.sh` only when explicitly asked to perform the final local installed-app integration check.
- When performing GitHub actions, use the `gh` CLI.
