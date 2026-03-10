# User-Facing Copy Guidelines (v1.1)

This app uses these rules for status text, prompts, and inline warnings.

## Writing Style
- Use direct, plain, active voice.
- Prefer clear verbs and concrete nouns.
- Include next-step guidance only when the user can act immediately.
- Avoid internal jargon in user-facing text (for example, do not use "staged").

## Preferred Terms
- Pre-apply state: **prepared** / **ready to apply**.
- Post-apply state: **applied**.
- Default noun: **metadata changes**.
- Use **metadata fields** only when field-count precision is important.

## Surface Rules
- Status bar: non-blocking updates, confirmations, and recoverable warnings.
- Inline sheet text: import warnings/errors that do not require an explicit acknowledgment.
- Modal dialogs: destructive actions, blocked workflows, and expectation-breaking outcomes requiring explicit acknowledgment.

## Message Patterns
- Success: `Verb + object + count`.
  - Example: `Applied metadata changes to 6 files.`
- Recoverable error: `Couldn’t + action + reason`.
  - Example: `Couldn’t apply metadata changes. 2 files were locked.`
- Pre-apply import summary:
  - `Prepared X metadata fields for Y files. Ready to apply.`
