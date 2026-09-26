# Cull Mode — Plan — 2026-09-26

Directional scoping for a v2.0+ feature, written up at the user's request
during a conversation about positioning v2.0 as a lightweight, native
Adobe Bridge competitor. **This is speculative, not committed** — no code
has changed, and the open questions below need real design decisions
before implementation starts. Tracked from `docs/ROADMAP.md`'s v2.0+ →
Browse section.

## The idea

A dedicated, full-window "Cull Mode" for rapidly reviewing and
flagging a batch of photos — the Photo Mechanic/Lightroom-culling
workflow, distinct from Ledger's existing metadata-editing focus.
Confirmed scope (2026-09-26): **general-purpose, activatable on any
folder at any time** — not a feature bolted only onto the import
pipeline, though entering it right after an import completes is one
expected entry point among others.

The visual precedent raised in conversation is Photos.app's Edit mode:
clicking Edit changes the whole window's chrome (dark bar, dedicated
tool row, a "Done" button top-right) to make it unambiguous that you've
left normal browsing/viewing and entered a distinct mode — not just
another panel or sheet. The proposal here is the same instinct applied
at the level of "you are now culling, not editing metadata," rather than
"you are now adjusting an image."

## What already exists (verified against code, not assumed)

This reuses more of the current app than it first looks like it would:

- **The data model already exists.** The Pick flag
  (`pick: Int`, -1/0/1 = Rejected/Not set/Picked) is already a first-class
  field, currently surfaced via `InspectorRatingFlagView`
  (`SharedUI/Inspector/InspectorRatingFlagView.swift`) — the same flag/
  button-based UI already used for star rating and colour labels. Cull
  Mode does not need a new concept or a new persisted field; it needs a
  purpose-built, full-screen UI for setting the *same* field rapidly,
  instead of one file at a time in the Inspector.
- **The handoff actions already exist and are exactly what "send picks
  to Lightroom" would call.** `sendToLightroom(_:)`/
  `sendToLightroomClassic(_:)`/`sendToPhotos(_:)`
  (`AppModel+Actions.swift`) already take an arbitrary `[URL]` — Cull
  Mode's exit action would just filter `browserItems` down to
  non-rejected (or only-picked) URLs and call the existing action, no new
  handoff mechanism.
- **The destructive-action convention already exists and should govern
  the delete-rejected path.** This v1.4 session did a full audit and fix
  pass on destructive buttons across the app (`role: .destructive` +
  `.buttonStyle(.bordered)` + `.tint(Color(nsColor: .systemRed))` for
  SwiftUI; `hasDestructiveAction` for AppKit) — a "Delete Rejected" action
  must follow the same convention, with the same kind of explicit
  confirmation as every other destructive action in the app (see
  `v1.4-manual-smoke-checklist-2026-09.md` §5 for the full list of
  precedent sites).
- **The menu-bar-always-populated architecture (v1.4 Phase 4.0/4.1)** is
  directly relevant to how Cull Mode's menu should behave — Ledger's menu
  bar is built to be fully present and correctly routed via the responder
  chain from launch, with no deferred-injection tricks. Whatever menu
  changes Cull Mode needs (a dedicated Pick/Reject/Advance menu, or
  temporarily disabling metadata-editing menu items) should follow that
  same "correct from the first frame" discipline, not reintroduce the
  kind of timing bug that phase fixed.

## Scope (proposed — needs confirmation, not yet agreed)

In scope, if this goes forward:
- A distinct full-window mode, entered from any folder at any time (a
  toolbar button and/or a menu item, not restricted to a post-import
  flow), with its own chrome treatment signaling "you are culling now."
- Rapid pick/reject/unflag on the existing `pick` field, keyboard-driven
  (single-key shortcuts matching the Photo Mechanic/Lightroom convention
  this app's target users already know — e.g. P/X/U — exact bindings TBD).
- Advance/step through the folder's contents without leaving the mode.
- Two **separate, explicitly-named** exit/resolution actions, never
  combined into one "Done" button:
  1. **"Send Picks to…"** (Lightroom / Lightroom Classic / Photos) —
     non-destructive, filters the existing handoff actions to the
     non-rejected (or only-picked) subset; everything stays on disk
     untouched.
  2. **"Delete Rejected"** — genuinely destructive, its own explicit
     confirmation, following the app's existing destructive-action
     convention exactly. Must never fire as a side effect of exiting the
     mode.
- Simply exiting the mode with no resolution chosen (a plain "Done"/
  Escape) must be a safe no-op — flags set during the session persist
  (they're just the existing `pick` field), nothing is sent anywhere,
  nothing is deleted.

Explicitly out of scope for now:
- Any actual image adjustment/editing (crop, exposure, etc.) — Cull Mode
  is about triage, not the Photos.app Edit-mode functionality it borrows
  the chrome idea from. Ledger doesn't do image editing at all today and
  this isn't proposing to start.
- Automatically triggering Cull Mode at the end of an import — the
  post-import entry point should be an offered/optional action (e.g. a
  button in the import-complete state), not a forced transition.

## Open questions (need real design decisions, not assumptions)

- **Layout**: single-image-with-filmstrip (Lightroom Loupe-style) or a
  dense grid with per-cell pick/reject overlays (closer to a culling-
  focused Gallery view)? These serve different review styles (careful
  one-at-a-time vs. fast bulk-scan) and may warrant supporting both,
  similar to how the browser already has List/Icon/Gallery view modes.
- **Star rating during Cull Mode**: pick/reject is the core action, but
  should the existing star-rating field also be settable without leaving
  the mode, or is that explicitly out of scope for a first version (pick/
  reject only, rating stays an Inspector-only action)?
- **Scope of "a folder" during the session**: does Cull Mode operate only
  on the currently-loaded folder's contents, or can it include a
  filtered/searched subset (relevant once "Bridge-class search, filter,
  and sort" — already on the v2.0+ roadmap — exists)?
- **Keyboard shortcut bindings**: needs a real decision informed by what
  this app's actual target users (photographers coming from Bridge/
  Lightroom/Photo Mechanic) expect, not invented from scratch — worth
  checking against Photo Mechanic's bindings specifically, since that's
  the dedicated culling tool in this space.
- **Menu bar behaviour while in the mode**: does the standard Edit/View/
  Image menu set stay as-is (with new cull-specific items added), or does
  entering the mode meaningfully change what's enabled/available
  (matching Photos.app's Edit mode, which does restrict the surrounding
  chrome)? Needs to be designed against the existing menu architecture
  (`v1.4-progress.md` Phase 4.0/4.1), not bolted on separately.
- **Chrome implementation approach**: Photos.app's dark Edit-mode chrome
  is a real window-appearance change, not just a SwiftUI color swap —
  needs a concrete AppKit approach (window appearance override,
  `NSVisualEffectView` material change, or similar) scoped before
  implementation, not assumed to be simple because the visual idea is
  simple.
