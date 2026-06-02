# Public Repository Checklist

Use this before changing `robinwettstaedt/mergehawk` from private to public.

## Before Making the Repository Public

- Confirm `scripts/release-github.local.env` has been copied to a password
  manager and deleted locally.
- Run a secret scan across the working tree and Git history.
- Review `.env`, token, certificate, and signing-key patterns in `.gitignore`.
- Confirm the MIT license is present.
- Confirm `SECURITY.md` is present and uses the intended private report
  address.
- Add public-facing install, update, and support documentation.
- Confirm the GitHub App setup instructions do not expose secrets and only use
  public app identifiers.
- Confirm GitHub Issues are enabled if public bug reports are wanted.
- Confirm Pull Request creation is restricted to collaborators only.
- Confirm Wiki, Projects, and Discussions are disabled.
- Confirm Dependabot vulnerability alerts and security updates are enabled.
- Confirm the default branch protection still blocks force pushes and branch
  deletion.
- Decide whether the first public GitHub Release should be draft, prerelease,
  or stable.

## After Making the Repository Public

- Add required reviewer protection to the `release` GitHub environment.
- Move release signing/notary secrets from repository secrets to environment
  secrets if GitHub exposes that option for the now-public repository.
- Run one manual draft release workflow to verify signing, notarization, DMG
  packaging, and Sparkle appcast generation.
- Verify the public `appcast.xml` and DMG URLs are reachable without GitHub
  authentication.
- Install the GitHub-distributed build and confirm the General settings update
  controls are visible.
- Run a manual Sparkle update check against a newer draft/internal test release
  before publishing a user-facing update.
- Revisit repository topics, description, and README badges once the release
  channel is proven.
