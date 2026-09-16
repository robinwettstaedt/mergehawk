# MergeHawk project guidance

- Use the shared vocabulary in `docs/glossary.md` when discussing product behavior, writing documentation, or naming tests.
- Treat the project as greenfield. Prefer direct, scoped implementations; add fallbacks, compatibility paths, defensive guards, migrations, or configuration only when the current work clearly requires them.
- Do not run `scripts/update-installed-app.sh` during normal verification. Run it only for an explicitly requested final local installed-app integration check.
- Use the `gh` CLI for GitHub actions.
