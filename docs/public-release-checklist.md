# Public Repository Checklist

Steps to take `robinwettstaedt/mergehawk` from a private repository to a public
one without leaking secrets or weakening the release supply chain.

The work is split into two tracks:

- **Inside the repo** — code, config, and committed files. Most of this is
  already in place; the boxes below record what to re-verify before flipping.
- **GitHub settings (outside the repo)** — repository, branch, and environment
  settings that live in GitHub's UI/API, not in the tree. Some are blocked on a
  paid plan or on the repo being public and can only be completed at flip time
  or after.

## Release model (context)

Releases run after pushes to protected `main` and through manual
`workflow_dispatch` from `main`. The workflow refuses unprotected or non-`main`
refs. It selects the next `0.1.x` patch from published stable releases in the
downloads repository before building; attempts that leave no public release do
not consume that patch. A published stable baseline is required. GitHub creates the
`v*` tag on the downloads repository's own default branch when the release is
created. There is intentionally **no tag-push trigger**. Keeping `main` the
single release source also keeps the door open for a future Mac App Store
pipeline to release from the same branch.

## Inside the repo

- [x] MIT `LICENSE` present.
- [x] `SECURITY.md` present (confirm the report address is the intended one
      before publishing).
- [x] `scripts/release-github.local.env` is gitignored; only repo-safe values
      (public Sparkle feed URL + public EdDSA key) live in
      `scripts/release-github.env`.
- [x] Release scripts and the workflow parse env files as inert `KEY=value`
      data instead of `source`-ing them.
- [x] Working-tree secret scan is clean (no tokens, private keys, `.p12`,
      `client_secret`; auth uses Keychain + device flow).
- [x] Ran a secret scan across the **full Git history** (`gitleaks detect`).
      Found a historical GitHub OAuth **client secret** in `GitHubOAuth.swift`,
      removed from the tree when auth moved to device flow. The current app and
      release pipeline do not use a client secret.
- [ ] **Revoke** that leaked client secret in the app's GitHub settings:
      generate a new client secret, then delete the leaked one (GitHub requires
      at least one to exist; the new one can stay unused). Revoking makes the
      value in history dead, so a history rewrite is **not** required — just
      re-run `gitleaks detect` before flipping public to confirm nothing else
      remains.
- [ ] Confirm `scripts/release-github.local.env` is saved in a password manager
      and the on-disk copy is deleted from every machine and worktree.
- [ ] Confirm any GitHub App identifiers referenced in code/docs are public
      client IDs only — no app private key or client secret.
- [ ] Add public-facing install / update / support docs to the README.
- [ ] Decide whether the first public GitHub Release is draft, prerelease, or
      stable.

## GitHub settings — before making the repo public

These can be done while still private.

- [ ] **Branch protection on `main`** blocks force pushes and deletions, and
      keeps `enforce_admins` on. (Currently configured — re-verify it survives
      the flip.) This is what the workflow's protected-branch gate relies on.
- [ ] **Repository → Settings → Secrets and variables → Actions**: confirm the
      release secrets exist and are correct (run
      `scripts/configure-github-release-secrets.sh --dry-run`). They currently
      live as repository secrets because environment required-reviewers are not
      available on a private Free plan.
- [ ] Decide feature surface: enable **Issues** if you want public bug reports;
      keep **Wiki / Projects / Discussions** off unless wanted.
- [ ] Restrict who can open PRs / push to collaborators only.
- [ ] Enable **Dependabot** alerts and security updates.
- [ ] Review repository **topics, description, and social preview** for a public
      audience.

## At flip time / after making the repo public

Required-reviewer and environment branch policies for the `release` environment
require a **public** repo (or a paid plan), so they cannot be set while private
Free. Do these once public:

- [ ] **`release` environment → required reviewers**: add the repo owner so
      signing/notarization secrets are gated behind a manual approval before any
      release job can read them. (Currently the `release` environment has **no
      protection rules** — the in-repo protected-`main` gate is the only control
      until this is added.)
- [ ] **`release` environment → deployment branch rule**: restrict deployments
      to `main` only.
- [ ] Move the release signing/notary/Sparkle secrets from **repository**
      secrets to **environment** secrets scoped to `release`.
- [ ] Enable **secret scanning** and **push protection** (free on public repos).
- [ ] Confirm branch protection and the `release` environment survived the
      visibility change.

## Validate the public release channel

- [ ] Run one manual **draft** release from `main` and verify signing,
      notarization, DMG packaging, and Sparkle appcast generation succeed.
- [ ] Confirm the public `appcast.xml` and DMG URLs are reachable **without**
      GitHub authentication (public Sparkle updates require anonymous access).
- [ ] Install the GitHub-distributed build and confirm the General settings
      update controls appear and a manual "Check for Updates" works against a
      newer internal/draft release before publishing a user-facing update.
