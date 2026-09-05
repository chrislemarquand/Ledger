# Native (Swift/IOKit) EOS-1V Driver — Feasibility Scoping

Exploratory scoping only — nothing here is committed or scheduled. Written up 2026-09-05 after a
conversation working through the idea interactively. This is a safety-critical area — a previous,
unrelated project in this exact space destroyed a camera. Read Part 0 before anything else in this
doc, and before any future work in this space.

## The original question

Ledger currently talks to the EOS-1V over the ES-E1 cable via a Python script
(`External/eos1v-serial/eos1v_tool.py`), invoked as a subprocess (`EOS1VSessionController`, the
same subprocess-JSON shape as `ExifToolService`). The question: how feasible would a native Swift
replacement be, given the low-level USB/serial protocol is already fully known (documented in
`eos1v_tool.py`'s own source)? Stated non-negotiable requirement: **new code must never write
something to the camera that the Python script doesn't.**

The user's own framing: this wouldn't improve a feature or performance metric — the real motivation
is not wanting a Python dependency buried in the app, provided it can be done safely.

## Part 0 — Read this first: a camera was destroyed doing exactly this once already

Before any of the technical scoping below, this must be understood. `archive/1vdriverresearch`
(a local-only branch, not pushed — it contains a 300MB disk image over GitHub's size limit) holds
a full from-scratch attempt at a native EOS-1V driver from March–August 2026. Its closeout document
(`1vdriver/docs/020_project_closeout_2026-08-29.md`, read in full as part of this scoping pass) is
required reading for anyone touching this again. Summary:

**What happened.** During a live testing session on 31 March 2026, the EOS-1V's mainboard was
permanently damaged. Canon no longer services this body; there is no test hardware from that
project. The camera used for *this* round of scoping (referenced in `docs/EOS-1V_ESE1_Settings_Reconstruction.md`
and the shipped v1.3 feature) is a **different, working** body — the destroyed one belonged to the
earlier project specifically.

**Root cause, reconstructed after the fact.** `0xF6` was classified as harmless "session control"
in a capture-*frequency* catalog (`spec/002_eos1v_readonly_opcode_catalog_v0.csv`) — built from how
often an opcode appeared in USB captures, not from what it does. A separate, disassembly-derived
document had the correct answer all along: **`0xF6` is `WriteSettings`.** The transport code
followed the frequency catalog, not the disassembly, and used `0xF6` as a warmup *and* teardown
opcode on every run — including a teardown that issued `0xF6` (beginning a settings write), fed it
one garbage byte, then dropped the serial line (deasserted DTR) 40ms later. That is a textbook
interrupted non-volatile-memory write — the classic unrecoverable-brick mechanism — and it ran on
every diagnostic run of the final multi-hour session.

**The project's own mandatory rules for anyone resuming this work**, direct quotes:
1. "Opcode allowlist derived from the disassembly, not capture frequency... Anything 'unresolved'
   defaults to *blocked*." The frequency catalog "must not be used as a safety input."
2. "`0xF6` is banned unless and until a full settings-payload format is confirmed."
3. "No writes in teardown. Deassert DTR and let the camera time out. Never issue a command and
   then drop the line."
4. "No opcode may be sent without an established `0xF2` session."

**Why this attempt is different — the load-bearing distinction.** The 2026 project had no
known-good reference; every opcode's meaning was inferred from USB capture frequency, a Windows
driver disassembly, and live experimentation against the one real camera. This proposal starts from
`eos1v-serial` (`External/eos1v-serial`, a git submodule) — a **working, already-shipped reference
implementation**, not a guess. It has been running Ledger's real, shipped clock-write feature
(see below) without incident, its opcode semantics come from genuine protocol understanding (not
frequency), and Ledger's own `EOS1VOpcode.swift` already transcribes it with the exact discipline
the destroyed-camera project arrived at only after the fact: *"never derive a write opcode
arithmetically... the transcribed tables below are the authority."* The stakes are identical
(a real, unique, hard-to-source camera) so every rule above carries forward unchanged — but the
starting position is fundamentally safer.

## Current architecture, and what's already true today

- `EOS1VSessionController` spawns `eos1v_tool.py machine <op>` as a subprocess and parses
  JSON-lines output — architecturally identical in shape to `ExifToolService`.
- Two independent, deliberate read-only gates already exist and predate this scoping pass: the
  Python side's `machine_main()` whitelists only `inspect`/`settings`/`download` (its own docstring:
  *"Versioned **read-only** subprocess interface for Ledger"*), and the Swift side's
  `EOS1VToolClient.Operation` enum only defines those three cases plus `setClock`, gated by an
  access-policy layer (`EOS1VToolAccessPolicy`) defaulting to `.readOnly`.
- **The only write path anywhere in the codebase is the camera clock**, added 2026-08-30
  (`docs/eos1v-set-clock-review-2026-08.md`) with real rigor already applied: an independent LLM
  review verified via AST diff that the patch changed zero existing functions
  (`set_clock`/`read_clock`/`frame_serial`/`clock_bcd`/`bcd`/`bcd6`/`_machine_inspect`/
  `_machine_settings` all untouched), and traced the full wire sequence a write sends — wake →
  status → pre-write reads → ack → register-select → ack → the six-byte packed-BCD value + checksum
  → ack → **read-after, verified, then teardown**. Confirmed identical whether triggered via the
  interactive CLI or the new `machine` route. That "complete, verify, *then* teardown" shape is
  exactly what the March incident's abrupt line-drop was not — it's the right template to build on.
- **Per `docs/ROADMAP.md`, clock-write is currently implemented but disabled** pending a real-
  hardware wake-failure diagnosis. Not a live production path today, but fully specified and
  reviewed.
- `EOS1VFrameDecoder.swift`/`EOS1VOpcode.swift`/`EOS1VRawDump.swift` already exist in Swift and
  decode **offline** — raw byte dumps of already-downloaded film/frame data. This never talks to
  the camera and carries none of the risk discussed here; it's unaffected either way.
- `EOS1VOpcode.swift` already catalogues the full read/write opcode table transcribed from
  `eos1v-serial`, with write opcodes explicitly marked "CATALOGUED, NEVER ISSUED" and a standing
  house rule: never derive a write opcode arithmetically (two of the four Custom Function write
  banks need a payload suffix no formula would produce — a fact `eos1v-serial`'s source captured,
  correctly, that a derivation would have missed).

## The transport itself

The ES-E1 cable is a real USB device (`04a9:3040`, a Canon-specific USB↔serial bridge chip, not a
generic FTDI/Prolific part a stock driver would recognize). `eos1v_tool.py`'s own source documents
it in full:

- **`UsbBridgeTransport`**: a fixed, already-captured sequence of 7 vendor control transfers
  (`SERIAL_INIT`) opens the bridge's internal UART — literal, known-good bytes, not something to
  re-derive. After that: plain bulk OUT/IN transfers (endpoints `0x02`/`0x81`), 64-byte packets,
  trivial `[length][0x00][payload]` framing.
- Above the transport, a transport-agnostic protocol layer (the same code also supports a raw FTDI
  serial cable via `SerialTransport`) implements the wake/status/register read-or-write sequence —
  9600 8N1, no flow control, no modem-control lines (camera side is 3-wire TXD/RXD/GND).

This maps cleanly onto macOS's native `IOUSBHostDevice`/`IOUSBHostInterface` (IOKit) — Apple's own,
first-party, always-present framework for exactly this class of vendor USB device, usable from an
unsandboxed app (Ledger already is) without libusb. The actual protocol work is porting known,
already-correct byte sequences and control flow, not discovering new ones — the hard reverse-
engineering is done and captured as literal data in a working reference.

## A concrete, non-aesthetic reason beyond "I don't like Python in the app"

Checked directly, not assumed: **`eos1v_tool.py` is not bundled into `Ledger.app` at all.**
`EOS1VSessionController.resolvedConfiguration()` falls back to a hardcoded path —
`~/Xcode Projects/Ledger/External/eos1v-serial/.venv/bin/python` — the developer's own source
checkout. No Xcode build phase copies the script, a Python runtime, or its virtualenv into
`Contents/Resources/` the way `exiftool` is bundled. Its one dependency, `pyusb`, itself needs the
native `libusb` shared library (confirmed present on this machine only via Homebrew,
`/opt/homebrew/Cellar/libusb/1.0.29`) — not bundled either. And `CHANGELOG.md` lists "EOS-1V direct
camera connection" as a **shipped** feature (v1.3).

This means: as far as the code shows, a customer who installed Ledger normally — no Homebrew, no
manually-created Python venv, no `pip install pyusb` — would see the Connect tab fail with
"Python was not found at ...", not a graceful explanation. **This was flagged to the user directly
as a finding to confirm, not assumed as fact** — it may be a known, accepted limitation (the feature
understood to work only on the developer's own machine so far), but if not, it reframes the whole
question: this isn't "replace working code for cleanliness," it's "this feature may not reach real
customers at all today," and the choice becomes bundling a Python runtime + pyusb + libusb properly
(real, nontrivial packaging/codesigning/notarization work) versus a native port that has no runtime
dependency to bundle in the first place — consistent with how the rest of the app already treats
third-party tools (`exiftool` ships as a self-contained bundled binary, not "install via Homebrew").

`pyusb`+`libusb` is also less ideal than IOKit independent of the bundling question: it's a
third-party dependency chain (interpreter → pyusb → libusb dylib → USB access) with a real history
of breaking across macOS USB-stack changes, versus `IOUSBHostDevice`, which is Apple's own,
always-present, forward-compatible-by-construction framework. The Python transport's own
`is_kernel_driver_active`/`detach_kernel_driver` calls are Linux-shaped concepts that don't map
cleanly onto how macOS handles vendor USB interface claiming — not necessarily broken, but a sign
the library wasn't designed with macOS as its primary target.

## Explicit scope for a first pass, per the user's instruction

**Only the operations Ledger actually issues today**: `inspect`, `settings`, `download`,
`set-clock`. Nothing from `eos1v-serial`'s wider CLI surface — no Custom Function writes, no
Personal Function writes, no `erase-all`, no reading the "items to be recorded" mask's write side.
Those all exist in `eos1v_tool.py` and are already catalogued (read-side) or explicitly banned
(write-side) in `EOS1VOpcode.swift`, but are out of scope until/unless a later, separately-scoped
pass deliberately extends coverage — each such extension should get the same rigor as this one, not
inherit it by default.

## Required safety approach — a staged trust model, not one leap

Carrying the closeout doc's mandatory rules forward as non-negotiable (verified-semantics-only
allowlist, no un-derived write opcodes, no teardown without confirmed completion, no opcode without
an established session), plus the byte-verification method requested:

1. **Offline byte-equivalence testing — zero hardware risk, and a hard gate before anything else.**
   Both `eos1v_tool.py`'s and the native Swift protocol layer are deterministic: the same logical
   operation with the same inputs must produce the same bytes, every time. Swap Python's transport
   for a capturing fake (no real USB device touched) and do the same on the Swift side; diff every
   byte sequence for all four in-scope operations, across every input variant Ledger actually uses
   (e.g. every `set-clock` mode: System/Shift/Specific). This is fully automatable and should be
   exhaustive, not a spot check, and should pass completely before step 2 begins.
2. **Live testing, read-only operations only, and extensively, first.** `inspect`/`settings`/
   `download` carry no persistent-write risk even in a failure mode (worst case: timeout or garbage
   read, not corruption). This is where the *native transport itself* — IOKit device claim, vendor
   control transfers, bulk I/O timing — gets proven reliable against the real camera, independent
   of the protocol-byte question already settled in step 1.
3. **The write path (`set-clock`) validated last, most conservatively, only after 1 and 2 are
   solid**, and only ever using the exact "complete → verify readback → *then* teardown" shape the
   existing reviewed Python implementation already uses. Never a teardown that fires without
   confirmed completion — that is precisely the March incident's mechanism.
4. **Consider a spare/backup EOS-1V body before any live testing of a new native transport**, not
   as a nice-to-have. The closeout doc names this as its own recommended precondition for resuming
   *any* work in this space, given the demonstrated failure mode. This is a real decision for the
   user, not something to default either way on.

## Recommendation

More tractable and comparatively lower-risk than the native EXIF idea scoped alongside this one —
the protocol is small, already fully documented in a working reference, and much of the read-side
transcription work already exists in Swift. But the stakes (a second, irreplaceable camera) are
categorically different from anything else in this app, so:

- Treat the offline byte-equivalence harness (step 1 above) as a hard prerequisite, not a
  nice-to-have alongside implementation — build and pass it before writing any code that opens a
  real USB handle.
- Scope strictly to the four operations named above for a first pass; do not let "we have the full
  protocol documented" become "so let's cover everything" — that expansion, if wanted later, is its
  own separately-scoped decision.
- Resolve the bundling/distribution question (is this feature actually reaching customers today?)
  as its own finding, independent of whether a native port happens — it may be higher-priority on
  its own.
- If pursued, this is naturally v2.0+/post-v2.0 work — no dependency on anything currently
  in-flight, and read-side work in particular is additive and low-risk enough to land on its own
  timeline whenever picked up.

## What this doc is not

A go-ahead. This is a feasibility scoping pass for an idea not yet decided on, written the same way
as `docs/native-exif-reader-feasibility-2026-09.md`. See `docs/ROADMAP.md`'s "Post-v2.0 —
Exploratory / Under Investigation" section for where this sits relative to committed work.
