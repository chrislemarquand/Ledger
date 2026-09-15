# Dependency Policy

## Current Mode: Local-Only SharedUI

- `SharedUI` must be referenced as a local path dependency: `.package(path: "../SharedUI")`.
- Do not reference `https://github.com/chrislemarquand/SharedUI.git` in normal development.
- Do not run remote/version bump workflow unless explicitly requested.

## Local Lockstep Workflow

1. Verify local dependency wiring and see how the current checkout compares to the recorded
   release revision (informational only — does not fail on drift):

```bash
./scripts/deps/verify_shared_ui_pin.sh
```

2. Resolve and build against whatever is currently checked out at `../SharedUI`. This never
   changes the recorded revision:

```bash
./scripts/deps/sync_sharedui_local.sh
```

## Accepting a New SharedUI Revision (Deliberate, Never Automatic)

`Config/SharedUI.revision` records the exact commit a release is validated against. Nothing
in ordinary development changes it. After verifying a new SharedUI commit locally, record it
explicitly:

```bash
./scripts/deps/bump_sharedui.sh          # pins SharedUI's current (clean) HEAD at ../SharedUI
./scripts/deps/bump_sharedui.sh <ref>    # pins a specific branch/tag/SHA instead
```

This requires `../SharedUI` to be clean — it refuses to pin an uncommitted state. Review and
commit the updated `Config/SharedUI.revision` like any other change.

## Preparing an Isolated Checkout

To verify a release builds from the recorded revision alone, without touching your own
`../SharedUI` working checkout (which may be mid-feature-work on some other branch):

```bash
./scripts/deps/prepare_sharedui_worktree.sh
```

This creates a separate, isolated `git worktree` at the recorded revision. Remove it with
`git -C ../SharedUI worktree remove <path>` once you're done with it.

## Release Mode (Only When Explicitly Requested)

- Before releasing, confirm the checkout actually matches the recorded pin:

```bash
./scripts/deps/verify_shared_ui_pin.sh --require-pin-match
```

- Switching back to a tagged remote `SharedUI` dependency is a release action.
- Do not perform that switch unless explicitly requested.
