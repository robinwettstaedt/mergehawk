# Contributing

Thanks for your interest in MergeHawk. It is maintained by one person, so the process is
kept small.

## Issues

Bug reports and feature requests are welcome. Please include your macOS version, the
MergeHawk version (Settings, then About) and steps to reproduce.

Report security issues privately as described in [SECURITY.md](SECURITY.md), not in a
public issue.

## Pull requests

- Open an issue first for anything beyond a small fix, so we can agree on the change before
  you spend time on it.
- Keep each pull request focused on one change.
- Make sure `swift test` and `swift run mergehawkcoretestrunner` pass. See
  [docs/development.md](docs/development.md).
- CI runs on every pull request. For first-time contributors it starts after a maintainer
  approves it.

Pull requests may be declined if they do not fit the direction of the app. All changes to
`main` go through a reviewed pull request.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
