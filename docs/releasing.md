# Releasing

## Overview

MergeHawk releases are GitHub Releases of this repository. Each release holds
exactly two assets: a signed, notarized DMG for Apple Silicon and the Sparkle
appcast that the in-app **Check for Updates** action reads. The app's feed URL is
`https://github.com/robinwettstaedt/mergehawk/releases/latest/download/appcast.xml`,
so the release marked latest is the one installed apps are offered.

Releases are started by hand. Pushes to `main`, including PR merges, publish
nothing. The **CI / Tests** PR check runs the release tooling tests before merge.

`scripts/build-private-installer.sh` is unchanged and separate. It builds a local
installer with updates disabled and is not part of this release channel.

## Starting a release

In GitHub, open **Actions**, then **Release**, then **Run workflow**. Keep the
branch on `main` and pick a bump type: `patch`, `minor` or `major`.

The CLI equivalent:

```sh
gh workflow run release-github.yml --ref main -f bump=patch
```

Only the repository owner can start or rerun a release. Runs from any other ref,
or started by anyone else, skip both jobs.

## Versions and tags

- The first release is `1.0.0`, whatever the bump type.
- After that, the workflow takes the highest published stable release and raises
  it: `patch` adds 1 to the patch number, `minor` adds 1 to the minor number and
  resets the patch, `major` adds 1 to the major number and resets the rest. From
  `1.2.3` that gives `1.2.4`, `1.3.0` or `2.0.0`.
- The tag is `vX.Y.Z` on the built commit. The bundle build number is the UTC
  build time as `YYYYMMDDHHMMSS`, and that is the number Sparkle compares.
- A release needs an unreleased head commit on `main`. A run fails without
  publishing if `main` moved during the build, if the commit is already the
  latest release, or if the tag already exists.
- To roll back, revert the change on `main` and release the new commit.
- A failed publish can be retried with **Re-run failed jobs** within a day, while
  the build artifact still exists and `main` is unchanged. Otherwise start a new
  run.

## How the workflow runs

The workflow is `.github/workflows/release-github.yml` and has two jobs.

The **build** job runs on macOS in the `release` environment with a read-only
token:

1. It checks out the dispatched commit without keeping Git credentials.
2. It reads the published releases and picks the next version.
3. It imports the Developer ID certificate into a temporary Keychain and stores
   the notarization credentials there.
4. It runs `scripts/release-github.sh`, which builds, signs, notarizes, staples
   and verifies the DMG, then signs the appcast. The Sparkle private key reaches
   only Sparkle's `generate_appcast`, on stdin.
5. It uploads the DMG and `appcast.xml` as a build artifact that expires after one
   day. Like every public release asset, any signed-in GitHub user can download
   it while it exists.
6. It deletes the temporary Keychain, even when an earlier step failed.

The **publish** job runs on Linux with a token that can write repository contents.
It receives no secrets and checks out no code. It downloads the artifact, checks
that the built commit is still the head of `main` and that the tag is free, then
creates the release with `gh release create`. GitHub generates the release
notes, and the release is marked latest.

Only one release runs at a time, and an active run is never cancelled.

## Secrets

All release secrets live only in the `release` environment, which accepts only
`main`:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `SPARKLE_PRIVATE_KEY`, matching the public key in `scripts/release-github.env`

The same environment holds the variable `DEVELOPER_ID_APPLICATION`, the signing
identity name. It is public, since every signed binary contains it.

To rotate a secret, run this and paste the new value at the hidden prompt:

```sh
gh secret set NAME --env release
```

Rules for contributors changing the workflow:

- Reference a secret only in the step that uses it, never at workflow or job level.
- Never print a secret.
- Never use `set -x` or `xtrace` in release scripts or workflow steps.

## Trust boundary

The owner is the only collaborator and the only person who can start a release.
Code merged to `main` is trusted, because a release workflow change merged to
`main` could reach the secrets.

Third-party Swift dependencies (Sparkle, SwiftSoup), pinned by the committed
package lock file, are trusted. They build in the same job that holds the signing
secrets, and the workflow doesn't try to isolate them. Only GitHub-owned actions
pinned by commit SHA are used.

A workflow on another branch of this repository can't receive the `release`
secrets. It could still create a fake release with its own write token. Users
couldn't install it, because Sparkle rejects an update that isn't signed with the
EdDSA key, but it could break the README download link or updates until removed.
This remaining risk is accepted.

## Local builds

`scripts/release-github.sh` builds and verifies release assets on an Apple Silicon
Mac from a clean worktree:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE="mergehawk-notary" \
scripts/release-github.sh --version v1.2.3 --build "$(date -u +%Y%m%d%H%M%S)"
```

It needs a Developer ID signing identity, a `notarytool` Keychain profile and a
Sparkle signing key in the Keychain (account `ed25519` by default, or
`SPARKLE_KEY_ACCOUNT`). `NOTARYTOOL_KEYCHAIN` can select the Keychain that holds
the notary profile. Assets land in `.build/releases/vX.Y.Z-<build>/assets/`. Use a
new build timestamp to retry.

`--dry-run --allow-dirty` prints the plan without building.

The gitignored `scripts/release-github.local.env` may hold only non-secret
settings, such as `DEVELOPER_ID_APPLICATION`, `NOTARYTOOL_PROFILE`,
`NOTARYTOOL_KEYCHAIN` and `SPARKLE_KEY_ACCOUNT`. The script rejects secret keys
in that file.

Local runs can't publish. Publishing happens only in the workflow's publish job.

## Tests

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/release -v
```
