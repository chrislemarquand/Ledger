# eos1v-serial capability audit (2026-08-30)

Cross-check of the ES-E1 settings surface (as reconstructed from the Mac OS 9
Instruction Manual, `EOS-1V_ESE1_Settings_Reconstruction.md`) against what
`eos1v-serial` (`eos1v_tool.py`) actually implements — read, write, and what
Ledger can reach via its `machine` JSON-lines subprocess interface.

No changes were made to `eos1v-serial` to produce this — it's a reading of
the existing source (register tables, decode functions, CLI commands, and
`machine_main()`'s dispatcher).

Four status levels used below:

- ✅ **Read, confirmed** — register located and decode verified against real
  hardware captures
- ⚠️ **Read, best-effort** — decodes but the byte mapping is explicitly
  flagged provisional/inferred in the source
- 🔧 **Write exists, CLI-only** — `eos1v_tool.py` can write it
  (`write-cfn`/`write-pfn`/`apply`/`set-clock`/`erase-all`), but **the
  `machine` interface Ledger calls only supports `inspect`/`settings`/
  `download` — none of these write paths are reachable from Ledger today**
- ❌ **Not supported at all** — no code path reads or writes it

## 1. Personal Functions (P.Fn-1–30)

**Enable bit** (the parent checkbox) is ✅ confirmed for all 30 — "verified
against the ES-E1 Combination tab" (`pfn_enabled`, byte 3-based).

Per-function value decode:

| P.Fn | Status | Note |
|---|---|---|
| 1 (shoot-mode mask), 2 (metering mask), 3 (metering enum), 12 (AI Servo sensitivity), 20 (frame limit), 30 (density) | ✅ | Confirmed bit/byte layout |
| 4 (shutter range), 5 (aperture range) | ✅ | Confirmed registers; the exact stepped value tables (`PFN4_SHUTTER_MAX/MIN`, `PFN5_APERTURE_*`) are transcribed from manual screenshots, not independently re-verified byte-by-byte |
| 19 (booster fps), 23 (timers) | ✅ | Confirmed |
| 25 (CLEAR-button defaults) | ✅ mostly | Shooting/metering/AF/focus-point sub-fields confirmed; **film-advance "High-speed continuous" byte (0x02) is explicitly marked "INFERRED" in source** — the one unconfirmed value in an otherwise-solid function |
| 6 (register/switch mode+metering) | ⚠️ | No register at all — "preset modes are stored on the camera body, not in these registers." Read shows enable-only; the manual's actual preset content isn't decodable |
| 7, 8, 9, 10, 11, 13, 14, 15, 16, 17, 18, 21, 22, 24, 26, 27, 28, 29 | ✅ | Simple on/off, decoded purely from the confirmed enable bit — no separate value register needed |

**Writing**: `write_personal_functions` exists and mirrors the read
registers, but is CLI-only (`write-pfn`, `apply`) — **not reachable via
`machine`**, so Ledger cannot write any P.Fn today regardless of confidence
level. Given P.Fn-25's one inferred byte, that's also the one function where
writing *would* currently carry real risk if it were ever wired up without
recalibration first.

## 2. Custom Functions (C.Fn-1–19, plus C.Fn-0)

✅ **All 20 fully confirmed** — the whole table (names, every option label,
byte encoding) is sourced from the ES-E1 Windows binary and "hardware-
confirmed... validated against two known camera states." This is the most
solid part of the whole tool. C.Fn-0 is deliberately read-only (hidden by
ES-E1 itself; body-only setting) — matches the manual exactly.

Custom Function **groups 0–3** (the manual's group-registration dropdown):
✅ all four banks (current + 3 stored) are read (`CFN_READ = [d5,d7,d9,d1]`)
and structurally writable (`CFN_WRITE_ORDER` covers all four) — again
CLI-only, not via `machine`.

**Writing**: 🔧 `write_custom_functions`/`write-cfn`/`apply` exist, same as
P.Fn — CLI-only, not exposed to Ledger.

## 3. Shooting Data dialog

- **Data Processing** (Load / Delete-after-load / Delete-without-load radio
  buttons): partially covered. `download()` = Load. **"Delete after loading"
  and "Delete without loading" have no equivalent at all** — the only delete
  primitive is `erase_all()`, which is all-or-nothing (single `0xe2` command,
  no selective per-roll delete) and is explicitly **rejected by the
  `machine` interface** ("Unknown operations, including 'erase-all', are
  rejected"). So Ledger can download, but has no path to delete anything
  on-camera, selective or otherwise.
- **Shooting Data Items to be Recorded** (the 16-checkbox item-selection
  screen): ❌ **read-only, and only the current state** — `_machine_items()`/
  the `0xe8` mask decodes what's *currently* configured to record (this is
  what feeds Ledger's Properties tab), but there is no code anywhere to
  *change* that mask. This whole screen is display-only in `eos1v-serial`.
- Per-item **decoded values** (Focal length, aperture, Tv, Av, ISO, exposure
  comp, flash, metering, film advance, AF mode, date/time, battery
  date/time, multiple-exposure): ✅ all confirmed and already flowing through
  `films_to_csv`/Ledger's roll parsing.
- **Focusing point selection** and **Custom Function settings** (as
  *recorded shooting-data fields*, not the live C.Fn/P.Fn state): ❌ not
  decoded — absent from `films_to_csv`'s column list entirely.

## 4. Properties dialog

- **Information / Model name**: ✅ read (`camera.model`).
- **User-settable No.**: ❌ **not implemented at all** — no read, no write.
  Shown as a disabled "—" placeholder in Ledger's Properties tab because
  there's genuinely no data source for it.
- **Date and Time**: ✅ read (`clockDate`/`clockTime`, confirmed `bcd6`
  decode). 🔧 Write exists (`set_clock`) but is CLI-only, not in `machine` —
  not reachable from Ledger.

## 5. EOS-1V Memory app

This entire app — folder organization, film/frame list views, search,
printing, thumbnails, the Frame/Film Data-Editing windows, CSV export dialog
— is a **separate downstream application** for organizing *already-
downloaded* data. None of it is a camera protocol operation; `eos1v-serial`
has no concept of it and isn't meant to. The closest overlap is CSV export,
which Ledger reimplements independently (matching Canon's exact per-roll
format) rather than depending on `eos1v-serial` for it.

## Summary

| Capability | Confirmed read | Best-effort/partial read | Write in `eos1v_tool.py` | Write reachable from Ledger (`machine`) |
|---|---|---|---|---|
| All 19 C.Fn + groups | ✅ | — | ✅ | ❌ (CLI-only) |
| P.Fn enable bits (30) | ✅ | — | ✅ | ❌ (CLI-only) |
| P.Fn values (11 of 30) | ✅ (10) | ⚠️ (P.Fn-25 one byte inferred) | ✅ | ❌ (CLI-only) |
| P.Fn-6 preset content | — | ❌ (no register) | — | — |
| Shooting-data per-frame fields | ✅ | — | n/a (not writable data) | n/a |
| Shooting Data Items to be Recorded (which fields get recorded) | ✅ (current state only) | — | ❌ | ❌ |
| Data Processing (delete after/without loading) | n/a | n/a | ❌ (only all-or-nothing erase exists) | ❌ (erase explicitly rejected) |
| Properties: User-settable No. | ❌ | — | ❌ | ❌ |
| Properties: Date/Time | ✅ | — | ✅ (`set_clock`) | ❌ (CLI-only) |
| EOS-1V Memory app (organizing/search/print/export) | n/a — separate app | | | |

**Bottom line**: read coverage is excellent and matches the manual almost
completely (only P.Fn-6's preset content and the "User-settable No." are
genuine gaps). Write coverage exists in `eos1v_tool.py` for C.Fn, P.Fn, and
the clock, but **none of it is exposed through the `machine` JSON interface
Ledger uses** — that's a deliberate, existing safety boundary. Two features
have no write path anywhere in the codebase at all: selecting which
shooting-data items get recorded, and selective (non-all-or-nothing)
deletion of stored rolls.

## Where the read-only boundary actually lives

Two independent, deliberately-closed gates — not one technical barrier, and
nothing here is blocked by the camera protocol or hardware itself:

- **`eos1v-serial` side**: `machine_main()`'s own docstring states it
  directly — *"Versioned **read-only** subprocess interface for Ledger."*
  It's a hard whitelist: `operation` must be exactly `inspect`, `settings`,
  or `download`; anything else raises
  `ValueError("usage: machine inspect | settings | download <csv> <raw>")`.
  The underlying Python functions a write operation would need
  (`write_custom_functions()`, `write_personal_functions()`, `set_clock()`,
  `apply_compute()`) already exist and work — they're exactly what the
  *interactive* CLI commands (`write-cfn`, `write-pfn`, `apply`,
  `set-clock`) already call. Adding e.g. `machine write-cfn <file>` would be
  small, mechanical plumbing: call the same function, emit a JSON
  `started`/`completed` event instead of the interactive
  `input("Type YES...")` prompt.
- **Ledger side, independently**: `EOS1VToolClient.Operation` (in
  `EOS1VSessionController.swift`) only defines three cases — `.inspect`,
  `.settings`, `.download` — there's no write case to even construct. And
  `EOS1VToolClient.init(policy: EOS1VToolAccessPolicy = .readOnly)` defaults
  to a policy whose `allowed` set is just `[.read]`; `.permits(.write)`/
  `.permits(.destructive)` return `false`. So even if `eos1v-serial` grew a
  `machine write-cfn` tomorrow, Ledger's own client has no code path to call
  it and a policy that would explicitly refuse to if it tried.

Opening either gate requires real code changes on that side — deliberately
not done as part of this audit, per the instruction not to modify
`eos1v-serial`'s functionality.
