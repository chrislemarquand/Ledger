# Inspector Token Field — Handoff for Next Developer

## What We Want

A keyword token field inside the inspector panel that:

1. **Looks identical to the other inspector text fields** — same grey background, same corner radius, same border/focus ring behaviour as `Title` and `Description`
2. **Token chips in the app accent colour** (teal — not system blue)
3. **Return key tokenises** the current input; comma is a literal character within a token so `Smith, John` stays as one token
4. **× button on each chip** removes it
5. **Grows vertically** as chips wrap to new lines
6. **Autocomplete** from a `[String]` suggestions list passed in
7. **No orange dot / Apply button activated** when user types tokens then deletes them all (i.e. pending-edit state clears correctly when field returns to empty)

## Where It Lives

| | Path |
|---|---|
| Component | `SharedUI/Sources/SharedUI/Inspector/InspectorTokenField.swift` |
| Call site | `Ledger/Sources/Ledger/InspectorView.swift` ~line 256 |
| Detection | `isKeywordTag()` ~line 677 matches `xmp-subject` and `iptc-keywords` |
| Suggestions source | `AppModel.knownKeywords()` in `AppModel+Editing.swift` |

The binding passed in is a `", "`-separated string (e.g. `"Film, Travel, Smith, John"`). Exiftool reads/writes `Subject`/`Keywords` in this format. The field must split and rejoin on `", "`.

## Rendering Context

The inspector panel renders inside an `NSVisualEffectView` sidebar panel. Each field group sits inside `InspectorSectionContainer` which has:

```swift
.background(
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.quaternary.opacity(0.35))
)
```

Individual fields use:

```swift
TextField("", text: binding)
    .textFieldStyle(.roundedBorder)
```

The grey you see on those fields is **not a custom color** — it is the standard macOS `NSTextField` with `.roundedBezel` rendering inside a vibrant sidebar context. The AppKit NSTextField adapts its fill to the vibrant rendering environment. That adaptive rendering is what makes it appear grey.

## What Was Tried and Why It Failed

### Attempt 1 — NSTokenField (NSViewRepresentable)

Used `NSTokenField` with `tokenizingCharacterSet = .newlines`.

**Failures:**
- **Background**: `NSTokenFieldCell` draws its own opaque white background in `drawInterior(withFrame:in:)` via `NSGraphicsContext`, completely independent of `drawsBackground`, `isBordered`, and CALayer settings. Setting `isBordered = false` + `drawsBackground = false` + `wantsLayer = true` + `layer.backgroundColor = .clear` had no effect on the cell's internal drawing.
- **Token chip colour**: `NSTokenFieldCell` does NOT use `NSColor.controlAccentColor` for chip colour. It uses a hardcoded private colour family. `NSAccentColorName` in Info.plist affects SwiftUI's accent and some AppKit controls (buttons, checkboxes) but not `NSTokenFieldCell`'s private drawing code. The only fix would be a full `NSTokenFieldCell` subclass overriding `drawInterior`, which is ~50 lines of opaque AppKit drawing that could break on any macOS update.
- **Height**: `fittingSize` in `intrinsicContentSize` override caused infinite recursion. `NSTokenFieldCell.cellSize(forBounds:)` via `sizeThatFits(_:nsView:context:)` did work for height, but this was the only success.
- **Token deletion bug**: `NSControlTextDidChange` does not fire when a token is deleted via keyboard (click-select + Delete goes through `deleteBackward:` directly). KVO on `objectValue` was added as a workaround.

**Conclusion**: `NSTokenField` cannot be styled via public API. Its visual appearance is controlled entirely by private `NSTokenFieldCell` drawing code.

### Attempt 2 — Custom SwiftUI token field with manual background

Replaced `NSTokenField` with a pure SwiftUI view:
- `TokenFlowLayout` (SwiftUI `Layout` protocol) wrapping `TokenChip` views + a `TextField`
- `TokenChip` renders in `Color.accentColor` — this works correctly
- Height via SwiftUI layout — this works correctly
- Pending-edit bug fixed (chips update binding immediately and synchronously)

**Background colour failures:**

| What was tried | Result |
|---|---|
| `Color(NSColor.controlBackgroundColor)` | Solid white — no adaptation to vibrant context |
| `Color(NSColor.controlColor)` | Also resolves to white in practice |
| SwiftUI `.background` + `.overlay` with `separatorColor` stroke | White field, visible outline — nothing like other fields |

**Root cause of background failure**: SwiftUI's `Color(nsColor:)` for shape fills resolves the NSColor to its static RGB value at render time. It does NOT pick up the vibrant/adaptive rendering that AppKit controls get when embedded in an `NSVisualEffectView` hierarchy. The grey appearance of other inspector fields comes from the AppKit `NSTextField` object rendering directly inside the vibrant view hierarchy — a path unavailable to a SwiftUI `RoundedRectangle.fill()`.

**Focus ring failure**: Custom `strokeBorder` overlay toggled via `inputFocused` state change appears instantly and draws inside the field boundary. The real macOS focus ring fades in over ~0.1s and draws **outside** the control's bounds, rendered by the AppKit focus ring system. Even with `animation(.easeInOut(duration: 0.1))` and a negative-inset background shape, the appearance doesn't match because it's SwiftUI-drawn rather than system-drawn.

## Current State of the File

`InspectorTokenField.swift` currently contains a working custom SwiftUI token field. **The logic is correct** — tokenisation, chip removal, binding sync, duplicate suppression, autocomplete popover, `ForEach(enumerated:)` for safe index-based removal. Only the visual appearance is wrong (white background, custom focus ring).

## What the Next Developer Should Try

### The Likely-Correct Approach: Use a Real TextField as the Background

The background problem can be solved by using an actual `TextField` with `.textFieldStyle(.roundedBorder)` as the visual container, rather than trying to replicate its appearance:

```swift
ZStack(alignment: .topLeading) {
    // This provides the EXACT visual background — because it IS a TextField
    TextField("", text: .constant(""))
        .textFieldStyle(.roundedBorder)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .opacity(inputFocused ? 0 : 1)   // hide when focused, show our ring instead
    
    // Focused state: match system focus ring exactly
    if inputFocused {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
    }
    
    // Actual content
    TokenFlowLayout(spacing: 4) {
        // chips + TextField(.plain)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
}
```

**Why this likely works**: The background `TextField` with `.roundedBorder` renders using AppKit's NSTextField directly inside the vibrant view hierarchy and therefore picks up the correct adaptive grey. All styling decisions are delegated to the system.

**Key details to get right:**
- The padding on `TokenFlowLayout` must match `NSTextField.roundedBezel`'s internal padding (approximately 6pt horizontal, 4–5pt vertical — measure empirically)
- `allowsHitTesting(false)` on the background field so it doesn't intercept taps
- The `ZStack` should take its size from the FlowLayout content, and the background TextField should stretch to match (`frame(maxHeight: .infinity)` inside the ZStack)
- For focus, hide the background TextField (it shows an inactive ring of its own) and show a custom overlay that matches the real focus ring

### Alternative: Inspect What Color SwiftUI Actually Uses

Run this in a macOS Playground or add temporary debug logging:

```swift
// In a view that sits in the same rendering context as the inspector fields:
let field = NSTextField()
field.bezelStyle = .roundedBezel
print(field.backgroundColor)         // what AppKit uses
print(NSColor.controlColor.cgColor)  // what we're currently using
```

Then use that exact CGColor value in the SwiftUI fill. Note that if it's a dynamic/adaptive color, `cgColor` may vary — you'd need to resolve it in `colorScheme` context.

### What Not to Try Again

- Any variation of `NSTokenField` — `NSTokenFieldCell` drawing cannot be overridden without reimplementing it in full
- `Color(NSColor.controlBackgroundColor)` — white, non-adaptive
- `Color(NSColor.controlColor)` — also resolves to white in practice
- `wantsLayer`/`layer.backgroundColor` on NSTokenField — doesn't affect cell drawing
- `.strokeBorder` overlay for focus ring — wrong geometry and no system animation

## Repo State

Both repos are on the following branches:

| Repo | Branch |
|---|---|
| Ledger | `codex/v1.2` |
| SharedUI | `main` |

The `InspectorTokenField.swift` in SharedUI has the current (visually incorrect but logically correct) implementation. All other v1.2 work is complete — the token field is the only outstanding visual issue.

## Key Constraints

- **AppKit-first project**: SwiftUI is used only in isolated leaf view islands. The inspector IS one of those islands, so pure SwiftUI is appropriate here.
- **Token format**: `", "` (comma-space) separated. Exiftool returns `Subject`/`Keywords` fields pre-joined in this format.
- **Return only tokenises**: `NSTokenField` used `tokenizingCharacterSet = .newlines`. Comma must be treated as a literal character so `Smith, John` is a single token.
- **No NSTokenField**: Do not attempt NSTokenField again. See above.
- **Deployment target**: macOS 26. All modern SwiftUI APIs are available.
