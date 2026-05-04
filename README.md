# vc-dash

Rough MVP for a local GitHub PR dashboard with intentional notifications.

## Current state

- Electron shell with a menu bar/tray process.
- React dashboard for PR status scanning.
- Local sync engine with first-sync silent baseline behavior.
- Notification event detection for comments, reviews, failed CI, and changes requested.
- GitHub OAuth device flow using direct GitHub API calls.
- Encrypted local token storage through Electron safe storage.
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

Without GitHub credentials, the app uses mock PR data. To use the built-in sign-in flow, create a GitHub OAuth app, enable device flow for it, then start Electron with its client id:

```sh
GITHUB_CLIENT_ID=your-oauth-client-id npm run electron:dev
```

The app will show a GitHub device code, open `https://github.com/login/device`, poll until authorization completes, store the access token encrypted in the Electron user data directory, and then sync your PRs.

The temporary env-token path still works for debugging:

```sh
GITHUB_TOKEN=ghp_your-token GITHUB_LOGIN=your-login npm run electron:dev
```

## Test

```sh
npm test
```
