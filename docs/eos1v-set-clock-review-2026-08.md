# EOS-1V clock write: safety review record

Status: implemented, 2026-08-30. This is Ledger's first and only write path
to the camera.

## What changed

`eos1v-serial/eos1v_tool.py` gained one new function (`_machine_set_clock`)
and one new `machine_main` branch (`set-clock`), purely additive, wrapping
the existing, unmodified `EOS1V.set_clock()` — the same method the CLI's
own `set-clock` subcommand has always called. No existing function
(`set_clock`, `read_clock`, `frame_serial`, `clock_bcd`, `bcd`, `bcd6`,
`_machine_inspect`, `_machine_settings`) was edited.

On the Ledger side: `EOS1VToolClient.Operation.setClock(Date)` is the only
case in that enum classified `.write`; `EOS1VSessionController`'s policy
was widened from `.readOnly` to `.readAndClockWrite` specifically to unlock
that one case. `EOS1VSessionController.writeClock(_:completion:)` performs
the write, then refreshes just the clock/settings fields via a cheap
re-inspect (`refreshCameraClock`) — deliberately not `search()`, which
would otherwise flip `state` through `.searching`/`.connected` and drop
`tabsEnabled`, kicking the user out of the Date and Time tab mid-flow.

The write is triggered from a new SwiftUI sheet, `EOS1VSetClockSheetView`
(System / Shift / Specific modes), presented from the previously-disabled
"Change Date and Time…" button in `EOS1VPropertiesViewController`.

## Independent review

Before implementing, the proposed `eos1v-serial` patch was reviewed by a
separate LLM instance, prompted to verify — by reading the real, current
`eos1v_tool.py` directly, not trusting any description of it — that the
patch introduced zero new camera-facing protocol behavior.

**Verdict: PASS.** Key findings:

- AST comparison of current vs. proposed source confirmed no changes to
  `set_clock`, `read_clock`, `frame_serial`, `clock_bcd`, `bcd`, `bcd6`,
  `_machine_inspect`, or `_machine_settings`.
- `_machine_set_clock` calls `EOS1V.set_clock()` exactly once and does
  nothing else camera-facing; the wrapper only reformats its return value.
- Traced the full serial sequence a write sends and confirmed it's
  identical whether triggered via the CLI's existing `set-clock`
  subcommand or the new `machine set-clock` route: wake (`0xFF`/`0xF4`) →
  `0xF6`, `0xF1` status → `0xF3` read (before) → `0xA1`, `0xD1` pre-write
  reads → `0xF9` ack → register-select frame for `0x1A` → `0xF8` ack → the
  six-byte packed-BCD clock value + checksum → ack → `0xF3` read (after) →
  `0xF2` teardown. No command, byte, or register address added, removed,
  or reordered.
- The new `machine_main` branch is reachable only via explicit
  `machine set-clock <ISO8601>` arguments; malformed/missing/extra
  arguments are rejected before any camera object is constructed.
- Existing `inspect`/`settings`/`download` branches, their gating, and
  their error handling are untouched.

Two gaps the review flagged, both fixed before implementation:

1. **Silent readback mismatch**: the CLI's own `set-clock` subcommand
   already detects when the post-write readback doesn't match what was
   written and prints a warning (tolerating a seconds-only difference).
   The original wrapper draft would have reported `"completed"`
   unconditionally. Fixed: `_machine_set_clock` now returns a `verified`
   boolean (`new[:5] == written[:5]`, matching the CLI's own tolerance).
2. **Stale docs**: `machine_main`'s docstring and usage-error string still
   described the interface as read-only. Fixed: both now mention `set-clock`.

## Regression tests

`tests/test_machine.py` gained three tests exercising the new dispatch
path with mocked cameras (no hardware): a successful write reports the
right JSON shape, a mismatched readback correctly reports `verified: false`,
and malformed/missing/extra `set-clock` arguments are rejected before any
camera object is even constructed. All pass; run via `python3 tests/run_all.py`
or `python3 tests/test_machine.py` directly.
