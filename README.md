# vc-dash

Rough MVP for a local GitHub PR dashboard with intentional notifications.

## Current state

- Electron shell with a menu bar/tray process.
- React dashboard for PR status scanning.
- Local sync engine with first-sync silent baseline behavior.
- Notification event detection for comments, reviews, failed CI, and changes requested.
- Direct GitHub GraphQL client.
- Mock PR source for local UI work.

## Run

Install dependencies first:

```sh
npm install
```

Start the renderer:

```sh
npm run dev
```

In a second terminal, start Electron:

```sh
npm run electron:dev
```

Without GitHub credentials, the app uses mock PR data. To fetch real GitHub data in this rough MVP:

```sh
GITHUB_TOKEN=ghp_your_token GITHUB_LOGIN=your-login npm run electron:dev
```

The planned production path is OAuth device flow plus macOS Keychain storage; the temporary env-token path exists only to make the MVP usable before auth UI is implemented.

## Test

```sh
npm test
```
