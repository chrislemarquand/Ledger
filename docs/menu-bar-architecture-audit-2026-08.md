# Menu Bar Architecture Audit — 2026-08-29

Diagnosis and fix plan for why Ledger's top-level menu bar (File/Edit/View/Image/Folder/Help) visibly arrives a beat after launch — reported while adding Edit-menu items for metadata copy/paste, where a mistake surfaced how fragile this area is. Diagnosis and plan only; no code changed as part of this document.

## What Ledger actually is

Worth stating precisely, since it's easy to mischaracterize (this document's author did, mid-session): Ledger's app shell is **pure AppKit**, not a SwiftUI app. `LedgerMain` (`Sources/Ledger/LedgerApp.swift:5-17`) is a plain `enum` with `static func main()` that constructs `NSApplication.shared`, assigns a manual `AppDelegate`, and calls `app.run()` — no `SwiftUI.App`, no `Scene`, no `.commands`. The window is a hand-built `NSWindow(contentViewController:)`; the menu bar is hand-built `NSMenu`/`NSMenuItem` objects, with no `MainMenu.xib`/storyboard. What Ledger *does* use SwiftUI for is individual content panes (the Inspector, various sheets) hosted inside that AppKit shell via `NSHostingController`/`NSHostingView`. That distinction — "an AppKit app that hosts some SwiftUI views" vs. "a SwiftUI app" — matters for everything below.

## How other Mac apps get an instant menu bar

- **Nib/storyboard-based AppKit apps**: `MainMenu.xib` is loaded by AppKit as part of the launch sequence, before `applicationDidFinishLaunching` even runs, before any window or view controller exists. The full menu structure is data, not code — it exists the instant the process is nominally "launched."
- **SwiftUI apps**: the whole menu bar is built declaratively via `.commands { }` on the `App`/`Scene`, evaluated once by the SwiftUI runtime as part of app startup — again independent of any specific view's lifecycle.

Both mechanisms decouple "the menu bar exists" from "some view finished loading."

## What Ledger does instead, and why it's late

Ledger's own top-level menus are injected at runtime into `NSApp.mainMenu` from inside `NativeThreePaneSplitViewController` — a content view controller that only runs its setup code once the window/view lifecycle reaches that point, which is inherently *after* `applicationDidFinishLaunching` has already shown the window. The actual deferral mechanism, `Sources/Ledger/MainContentView.swift:335-361`:

```swift
DispatchQueue.main.async { [weak self] in
    self?.focusBrowserPane()
    self?.injectFileMenuIfNeeded()
    self?.injectEditMenuIfNeeded()
    self?.injectSortMenuIfNeeded()
    self?.injectImageMenuIfNeeded()
    self?.injectFolderMenuIfNeeded()
    self?.injectHelpMenuIfNeeded()
}
// Re-register menu delegates every time the user clicks the menu bar.
// SwiftUI may rebuild NSMenu objects after our initial async setup, invalidating
// the weak references. didBeginTrackingNotification fires before menuWillOpen,
// so delegates are always current by the time injection is needed.
menuTrackingObserver = NotificationCenter.default.addObserver(
    forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
) { [weak self] _ in
    MainActor.assumeIsolated {
        self?.injectSortMenuIfNeeded()
        self?.injectFileMenuIfNeeded()
        self?.injectEditMenuIfNeeded()
        self?.injectImageMenuIfNeeded()
        self?.injectFolderMenuIfNeeded()
        self?.injectHelpMenuIfNeeded()
    }
}
```

The existing comment confirms this isn't incidental: hosting SwiftUI views inside an AppKit app causes SwiftUI's runtime to independently reach in and mutate `NSApp.mainMenu` on its own — a known cross-framework side effect, not something Ledger's code does deliberately. Ledger's own injection code defends against it two ways:

1. **Deliberately deferred by one run-loop tick** (`DispatchQueue.main.async`) so it happens *after* whatever SwiftUI does on its own — this is the literal, visible "beat behind" at launch.
2. **Re-injected defensively on every single menu-bar click** (`NSMenu.didBeginTrackingNotification`) in case SwiftUI clobbers the menu bar again later, since the injected submenus are held by `weak var ... ForInjection` references that can be invalidated by such a rebuild.

Separately, most of these top-level menus populate their real content lazily via `NSMenuDelegate.menuWillOpen` (only when the user actually opens that menu) rather than being fully built up front — a further departure from nib/`.commands` convention, where the full item structure (if not every dynamic title) typically exists from the start and `validateMenuItem` alone handles per-display state.

This structure is also *why* the field-level/metadata-set copy/paste Edit-menu attempt (this same session) caused a real regression: a couple of these rebuild functions (View menu, per an existing comment about registering Zoom shortcuts) call their *full* rebuild eagerly once at injection time too, specifically so keyboard shortcuts exist from launch — not just lazily on open. That eager path was, until this session, only ever used for cheap synchronous in-memory work. Adding a live `NSPasteboard.general` read to a function shared by both the eager and lazy paths put real IPC on the eager launch path for the first time, stalling the whole menu bar. The fix applied was to keep the eager path pasteboard-free and move dynamic content to the lazy `menuWillOpen` path only — but the underlying architecture (two different timing contracts sharing one function, undocumented) is what made that mistake easy to make, and will make it easy to repeat.

## Fix options

1. **Find and force the SwiftUI menu-mutation trigger early, then go synchronous.** If it's specifically "the first `NSHostingView`/`NSHostingController` instantiated in the process" that causes SwiftUI to touch the menu bar, deliberately instantiate a throwaway one at the very start of `applicationDidFinishLaunching` (before building the real window) to absorb that mutation up front. Then inject Ledger's own menus synchronously right after, with no `DispatchQueue.main.async` defer and no defensive re-injection needed. Smaller, more surgical change; keeps today's runtime-injection architecture; removes the workaround's root cause instead of timing around it. Risk: depends on correctly identifying the exact trigger, which isn't confirmed — would need investigation/instrumentation first (e.g. logging whenever `NSApp.mainMenu`'s identity or item count changes, to catch the SwiftUI-driven mutation in the act).
2. **Build the menu bar's structure once, up front, independent of any view controller's lifecycle** — the actual native-convention fix, matching what a `MainMenu.xib` or `.commands` gives other apps for free. Construct all six top-level menus (File/Edit/View/Image/Folder/Help) with their static item scaffolding in `applicationWillFinishLaunching`/`applicationDidFinishLaunching`, before any window exists — not from inside `NativeThreePaneSplitViewController`'s view lifecycle. Keep `NSMenuDelegate`/`menuWillOpen` strictly for populating *dynamic* content (checkmarks, live sidebar-derived items) right before display, never for the menu's mere existence. Larger, more invasive change — touches every `injectXMenuIfNeeded`/`rebuildXMenu` pair — but is the actual fix, not a workaround, and would let injection code stop worrying about SwiftUI's menu-bar side effects entirely (nothing SwiftUI does after the menu bar already has AppKit-authored content should need defending against, since AppKit owns `NSApp.mainMenu` from before any `NSHostingController` exists).

**Recommendation**: attempt option 1 first as a time-boxed investigation — if the SwiftUI trigger is a single identifiable point (plausible, given it's described as happening once "after initial async setup"), it's a small, contained fix. If it turns out to be less deterministic than that (e.g. SwiftUI touches the menu bar lazily per-view, unpredictably), fall back to option 2, which is correct regardless of how SwiftUI behaves since it removes the ordering dependency entirely.

## Relationship to existing roadmap items

This overlaps and should likely be tackled alongside — not instead of — the existing v1.4 item **"macOS 26 chrome-workaround audit on Golden Gate"** (`docs/Roadmap.md`), which already covers "window-config timing flashes" as one of several Liquid Glass-era AppKit/SwiftUI interop workarounds slated for re-test and retirement. This is the same class of problem (a timing workaround for cross-framework interference that may no longer be necessary, or was never fully correct), just a different symptom (menu bar vs. window chrome).

## Files referenced

- `Sources/Ledger/LedgerApp.swift:5-17, 90-111, 146-166` — app entry point, `configureApplicationMenu()`, `applicationDidFinishLaunching`.
- `Sources/Ledger/MainContentView.swift:322-362` — `configureWindowIfNeeded()`, the async injection deferral, `didBeginTrackingNotification` defensive re-injection.
- `Sources/Ledger/MainContentView.swift` — the six `injectXMenuIfNeeded()`/`rebuildXMenu()` pairs (File/Edit/View(Sort)/Image/Folder/Help).
- `docs/Roadmap.md` (v1.4) — "macOS 26 chrome-workaround audit" item, closest existing tracked relative.
