---
name: mergehawk-verification
description: Use during and after implementing a MergeHawk issue to verify meaningful implementation slices, final code, UI, mock app behavior, screenshots, and review artifacts before reporting work ready for user review.
---

# MergeHawk Verification

Use this during implementation after meaningful slices, and after implementation before telling the user the work is ready for review. When code changed, run `mergehawk-simplification` before final verification.

## Goal

Verify the implementation enough that the user can review behavior rather than discover basic breakage. Keep verification scoped to the issue and the approved plan.

## Incremental Verification

Use the lightest relevant check after each meaningful implementation slice:

- focused tests or runner commands when a narrow behavior changed
- `scripts/verify-ui.sh` after UI, copy, layout, filtering, sorting, or visual-state slices
- isolated app slot verification after runtime behavior becomes coherent enough to inspect
- full `scripts/verify.sh` before final user review

Do not run expensive checks after every tiny edit. Match verification cost to risk and scope.

## Required Checks

Before final user review, run the default verification:
   ```sh
   scripts/verify.sh
   ```
For UI, copy, menu layout, filtering, sorting, notification presentation, or visual state changes, run:
   ```sh
   scripts/verify-ui.sh
   ```
   Inspect the generated screenshots under `.build/verification/ui`.

Before reporting completed feature work ready for user review, always open an
isolated mocked app slot using the Linear issue id:
   ```sh
   scripts/run-agent-app.sh --slot <ISSUE-ID> --mock --open
   ```
   Example:
   ```sh
   scripts/run-agent-app.sh --slot MER-12 --mock --open
   ```
This is required even when static screenshots are sufficient. The user expects
the slot app to be open so they can personally inspect the finished feature.
This review slot should remain open until the user approves PR handoff; after
that, `mergehawk-pr-handoff` owns slot teardown and should close/remove it by
default unless the user explicitly asks to keep it open in that handoff turn.

For interactive UI verification, prefer Codex computer-use tools when available. Inspect the running slot app and capture relevant screenshots or notes under:
   ```text
   .verification/<ISSUE-ID>/
   ```
For macOS local notification behavior, inspect:
   ```text
   .build/agent-slots/<ISSUE-ID>/notifications.jsonl
   ```

## App Slot Review

The slot app opens as a real macOS app on the user's machine, usually at:

```text
~/Applications/MergeHawk <ISSUE-ID>.app
```

Leave the slot app open for user review after finishing feature work, before PR handoff. State the exact app name and what state it is showing. Do not replace or relaunch the user's normal installed app. Do not carry this instruction into PR handoff; that phase tears down the slot by default.

The slot must be inspectable by the user through LaunchServices, not only by
directly executing a binary. After running `scripts/run-agent-app.sh`, confirm
that `open ~/Applications/MergeHawk\ <ISSUE-ID>.app` succeeds and that the
app bundle's `CFBundleExecutable` points to a real Mach-O executable. Mock-mode
isolation should come from `LSEnvironment` in `Info.plist`, not from making the
bundle executable a shell wrapper.

Do not run `scripts/update-installed-app.sh` as part of normal verification. The normal installed app update is reserved for an explicit user-requested final local integration check after verification passes.

## Blocked Verification

If verification cannot be completed, report exactly what was skipped and why. Examples:

- computer-use tools unavailable
- app slot failed to launch
- screenshot capture failed
- a required service or credential is unavailable
- a verification command failed

When possible, leave the isolated slot app open for manual review even if automated visual inspection is blocked.

## Output

When verification is complete, report:

```md
## Verification Summary

Commands run:
Results:
UI artifacts:
Interactive app slot opened:
Interactive app slot path:
LaunchServices/executable checks:
Notification artifacts:
Skipped or blocked checks:
Ready for user review: yes/no
Next: user review, then mergehawk-pr-handoff when approved
```

Do not open a pull request in this skill. Wait for user approval, then use `mergehawk-pr-handoff`.
