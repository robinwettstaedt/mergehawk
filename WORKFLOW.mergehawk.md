---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "mergehawk-544f3c747bd2"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
    - Duplicate
polling:
  interval_ms: 15000
workspace:
  root: ~/code/mergehawk-symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:robinwettstaedt/vc-dash.git .
    mkdir -p .codex
    cp -R /Users/robin/projects/symphony/.codex/skills .codex/
  before_remove: |
    true
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working autonomously on Linear issue `{{ issue.identifier }}` for the Mergehawk project.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Work only inside the provided workspace checkout of `vc-dash`. Do not edit the user's main checkout.

## Required Context

Before changing code:

- Read `AGENTS.md`.
- Read `docs/agent-workflow.md`.
- Read `docs/glossary.md` when the task involves product wording.
- Inspect the current branch, status, and HEAD.

## Linear Workflow

- If the issue is `Todo`, move it to `In Progress` before implementation.
- Use a single persistent Linear comment headed `## Codex Workpad` for plan, progress, acceptance criteria, validation, and blockers.
- Keep the workpad current as facts change. Do not create separate progress comments.
- When implementation and validation are complete, create or update a GitHub PR and move the issue to `In Review`.
- If blocked by missing auth, missing permissions, or an unavailable required external service, record the blocker in the workpad and move the issue to `In Review`.
- If the issue is already terminal (`Done`, `Canceled`, or `Duplicate`), do nothing.

## Implementation Workflow

1. Reproduce or inspect the current behavior before editing, and record the signal in the workpad.
2. Sync with `origin/main` before implementation.
3. Create a branch using the issue identifier, for example `codex/rob-5-review-request-column`.
4. Implement the smallest coherent change that satisfies the issue.
5. For meaningful out-of-scope work discovered during implementation, create a follow-up Linear issue instead of expanding scope.
6. Commit changes with a concise imperative message.
7. Push the branch and open or update a PR.

## Verification

Follow `docs/agent-workflow.md`.

Default validation:

```sh
scripts/verify.sh
```

For UI/menu/layout/copy changes, also run:

```sh
scripts/verify-ui.sh
```

If an installed app bundle is needed, use an isolated agent slot:

```sh
scripts/run-agent-app.sh --slot {{ issue.identifier }} --mock --no-open
```

Do not run `scripts/update-installed-app.sh` unless the user explicitly requests a final installed-app integration check.

Final response must include:

- changed files,
- validation commands and results,
- PR URL if created,
- blockers if any.
