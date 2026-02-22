# Native Mac Branding + Naming Refresh

## 1) Brand Brief (One Page)

### Positioning
Finder-level utility polish for photo metadata: fast, clear, native, and trustworthy for high-volume editing.

### Personality
Calm precision with creative studio confidence.

### Voice
- Clear, concise, and utility-first
- Confident but not technical-jargony
- Quietly premium (no novelty phrasing)

### Visual Principles
- Native spacing and geometry (macOS-first proportions, rounded-rect rhythm)
- High material quality (light depth, subtle highlights)
- Restrained motion (functional transitions only)
- Moderate Liquid Glass (translucency/specular accents, avoid high-gloss chrome)

### Typography
- SF Pro Text / SF Pro Display as the primary system family
- Numeric/tabular emphasis where metadata values are dense
- Avoid decorative display typography in primary app chrome

### Color Tokens
| Token | Hex | Usage |
|---|---|---|
| `brand.cyan.500` | `#2AA9E0` | Primary icon core, focus accents |
| `brand.cyan.300` | `#79D2F2` | Glass edge glow, hover tint |
| `brand.graphite.900` | `#1C232B` | Primary dark neutral |
| `brand.graphite.700` | `#39444F` | Secondary neutral surfaces |
| `brand.graphite.500` | `#66717D` | Disabled/quiet separators |
| `brand.silver.200` | `#DDE5EC` | Light glass highlights |
| `brand.silver.100` | `#EEF3F7` | Light background neutral |
| `brand.white.alpha` | `rgba(255,255,255,0.42)` | Specular layer |

### Contrast Rules
- Light mode: graphite text/icons on silver surfaces, cyan used sparingly for active state only.
- Dark mode: silver text/icons on graphite surfaces, cyan shifted +8 to +12 brightness for visibility.
- Never place cyan text over cyan glass; reserve cyan for shape accents and selection cues.

### Icon Constraints
- Squircle-safe silhouette with optical center slightly above midpoint
- Motif: integrated lens + metadata grid in one glyph
- Legibility must hold at 16px, 32px, 64px (no thin decorative lines)
- Depth is subtle (1-2 translucent layers max), no neon, no heavy radial gradients
- Monochrome fallback must preserve lens-vs-grid distinction

## 2) Naming Framework + Scored Shortlist

### Hard Constraints
- One word
- 5-9 characters
- Abstract / native utility tone
- No explicit EXIF/metadata/photo wording
- Pronounceable and premium

### Weighted Rubric
- Native Apple-adjacent feel: 30
- Memorability: 20
- Metadata-workflow semantic fit: 20
- Visual/logo potential: 15
- Collision risk quick-screen: 15

### Candidate Scores
| Name | Len | Rationale | Risk Notes | Native (30) | Mem (20) | Fit (20) | Visual (15) | Collision (15) | Total |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|
| **Lucent** | 6 | Conveys clarity/light without being photo-explicit. | Existing uses in software/lighting; legal screen needed. | 27 | 16 | 17 | 14 | 9 | **83** |
| **Velora** | 6 | Soft premium tone, modern and brandable. | Some existing wellness/consumer naming overlap. | 25 | 17 | 16 | 14 | 10 | **82** |
| **Strata** | 6 | Implies structured layers; strong metadata metaphor. | Common term; search noise likely high. | 24 | 16 | 18 | 13 | 8 | **79** |
| **Nodal** | 5 | Suggests nodes/structure in a utility-forward way. | Slightly technical tone could feel less premium. | 23 | 14 | 17 | 12 | 11 | **77** |
| **Aeris** | 5 | Lightweight, calm, and platform-native sounding. | Existing products in other domains; screen needed. | 24 | 15 | 14 | 13 | 10 | **76** |
| **Calyx** | 5 | Distinctive, compact, and icon-friendly shape. | Botanical meaning may feel less utility-specific. | 22 | 16 | 14 | 13 | 11 | **76** |
| **Vanta** | 5 | Dark-neutral premium tone, concise and modern. | Strong association with existing brands/material names. | 23 | 16 | 13 | 13 | 9 | **74** |
| **Axiom** | 5 | Precision-oriented and trustworthy utility vibe. | Heavy existing use in tech/legal entities. | 22 | 15 | 15 | 11 | 10 | **73** |
| **Lattice** | 7 | Strong grid/structure signal relevant to metadata. | More technical than native-consumer tone. | 21 | 13 | 18 | 11 | 9 | **72** |
| **Nexora** | 6 | Contemporary and polished, neutral semantics. | May read synthetic/less timeless. | 21 | 15 | 13 | 13 | 10 | **72** |

### Top 3 Finalists
1. **Lucent** (83)
2. **Velora** (82)
3. **Strata** (79)

### Approved Name Decision
- Final product name: **Lattice**
- Decision rationale: strongest fit to metadata organization + grid semantics while keeping a premium utility tone.

## 3) Icon Concept Direction Sheet (Finalists)

Shared system across all routes:
- Palette: cyan + graphite + silver
- Material: moderate Liquid Glass
- Baseline: squircle-safe, optical center +3%
- Test sizes: 16px / 32px / 64px with monochrome fallback

### Finalist: Lucent

#### Route A: Utility-forward glyph
- Shape construction: central circular lens cut into a 3x3 rounded metadata grid; outer grid corners clipped for macOS softness.
- Light/material: single translucent cyan lens layer over graphite base; silver top-edge specular at 15-20% opacity.
- Monochrome fallback: lens = solid circle; grid = 2 vertical + 2 horizontal breaks.
- Legibility: ensure grid stroke never below 1 px at 32 px render; collapse inner detail at 16 px to 2x2.
- Finder/Photos differentiation: avoid flower-petal camera form; keep geometry orthogonal and inspector-like.

#### Route B: Creative-studio expression
- Shape construction: offset lens overlaps grid with slight diagonal drift (+6 degrees) to imply creative motion.
- Light/material: secondary cyan glow ring (subtle); thin silver refraction arc on upper-right quadrant.
- Monochrome fallback: preserve overlap by using knock-out seam between lens and grid body.
- Legibility: remove glow entirely below 64 px; retain only primary seam and 2 grid breaks.
- Finder/Photos differentiation: keep icon internally structural (grid-first), not lens-first.

### Finalist: Velora

#### Route A: Utility-forward glyph
- Shape construction: vertical pill lens centered over columnar metadata tiles (3 stacked rounded bars).
- Light/material: cyan lens core with graphite tiles; thin highlight line across top third.
- Monochrome fallback: pill + three bars with fixed spacing ratio 1:0.6:0.6.
- Legibility: enforce minimum negative space of 1.5 px at 32 px.
- Finder/Photos differentiation: no multi-color petals, no camera body silhouette.

#### Route B: Creative-studio expression
- Shape construction: lens intersects stepped grid blocks, creating a subtle parallax effect.
- Light/material: add soft inner-shadow on lower-left for depth; cap highlight intensity to avoid gloss look.
- Monochrome fallback: keep stepped blocks, remove shadow and highlight.
- Legibility: reduce to two stepped blocks at 16 px while preserving lens dominance.
- Finder/Photos differentiation: emphasize data blocks over photographic-object metaphors.

### Finalist: Strata

#### Route A: Utility-forward glyph
- Shape construction: concentric lens rings integrated with 4 horizontal layer bars (strata motif).
- Light/material: graphite layers with cyan core ring; silver separator lines at low opacity.
- Monochrome fallback: two rings + three bars only.
- Legibility: ring thickness scales non-linearly (thicker at small sizes) for retention.
- Finder/Photos differentiation: layer bars keep identity as metadata stack, not camera icon.

#### Route B: Creative-studio expression
- Shape construction: layer bars arc gently around lens center, suggesting fluid organization.
- Light/material: restrained cyan-to-cyan-light transition on ring edge; one specular highlight.
- Monochrome fallback: fixed arc bars with no gradient.
- Legibility: flatten arc curvature under 32 px to prevent shimmer artifacts.
- Finder/Photos differentiation: prioritize layered-structure motif and avoid literal aperture blades.

## 4) Rename Blueprint (Implementation Ready, No Code Mutation Yet)

Final naming locked for this blueprint:
- `APP_NAME` = `Lattice`
- `BUNDLE_ID` = `com.chrislemarquand.Lattice`

### A) Identity + Build Settings
| File | Line(s) | Current | Planned Change |
|---|---:|---|---|
| `/Users/chrislemarquand/Documents/Photography/Exifedit/ExifEditMac.xcodeproj/project.pbxproj` | 47, 106, 217 | `Logbook.app` | Rename product ref to `Lattice.app` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/ExifEditMac.xcodeproj/project.pbxproj` | 413, 435 | `INFOPLIST_KEY_CFBundleDisplayName = Logbook;` | Set to `Lattice` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/ExifEditMac.xcodeproj/project.pbxproj` | 421, 443 | `PRODUCT_BUNDLE_IDENTIFIER = com.chrislemarquand.Logbook;` | Set to `com.chrislemarquand.Lattice` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/ExifEditMac.xcodeproj/project.pbxproj` | 422, 444 | `PRODUCT_NAME = Logbook;` | Set to `Lattice` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/ExifEditMac.xcodeproj/project.pbxproj` | 479, 493 | `com.chrislemarquand.LogbookTests` | Optionally align to new test bundle naming |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/ExifEditMac.xcodeproj/xcshareddata/xcschemes/ExifEditMac.xcscheme` | 19, 61, 78 | `BuildableName = "Logbook.app"` | Update to `Lattice.app` |

### B) Runtime Strings + UI Labels
| File | Line(s) | Current | Planned Change |
|---|---:|---|---|
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/ExifEditMacApp.swift` | 21 | `About Logbook` | `About Lattice` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/ExifEditMacApp.swift` | 312 | fallback `"Logbook"` | fallback `Lattice` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/ExifEditMacApp.swift` | 454 | `window.title = "Logbook"` | `window.title = "Lattice"` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Config/ExifEditMac-Info.plist` | 24 | `Copyright © ... Logbook` | update to `Lattice` |

### C) Persistent Domains + Notifications + Defaults
| File | Line(s) | Current | Planned Change |
|---|---:|---|---|
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/AppModel.swift` | 3406, 3412 | `domain: "Logbook.Rotate"` | rename to `domain: "Lattice.Rotate"` + migration read fallback |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/AppModel.swift` | 3444, 3450 | `domain: "Logbook.Flip"` | rename to `domain: "Lattice.Flip"` + migration read fallback |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/MainContentView.swift` | 10, 11 | `Notification.Name("Logbook....")` | rename namespace to `Lattice` namespace |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/MainContentView.swift` | 152, 155 | `Logbook.MainSplit` / `Logbook.ContentSplit` | new autosave names (`Lattice.MainSplit` / `Lattice.ContentSplit`) |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/MainContentView.swift` | 167-170, 210-211 | old split-view defaults keys | one-time migration copy old keys to new keys |

### D) App Support Directories
| File | Line(s) | Current | Planned Change |
|---|---:|---|---|
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/AppModel.swift` | 80, 131 | `.../Application Support/Logbook` | move to `.../Application Support/Lattice` with fallback read |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/Sources/ExifEditMac/Presets.swift` | 75 | appending `Logbook` path | switch to `Lattice` folder |

### E) Release + Distribution Artifacts
| File | Line(s) | Current | Planned Change |
|---|---:|---|---|
| `/Users/chrislemarquand/Documents/Photography/Exifedit/scripts/release/archive.sh` | 8 | `ExifEditMac.xcarchive` | `Lattice.xcarchive` or stable project naming policy |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/scripts/release/archive.sh` | 26 | `.../ExifEditMac.app` | `.../Lattice.app` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/scripts/release/release.sh` | 9 | `ExifEditMac.zip` | `Lattice.zip` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/scripts/release/create_dmg.sh` | 5 | usage expects `ExifEditMac.app` | update usage text to `Lattice.app` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/scripts/release/create_dmg.sh` | 13 | `ExifEditMac.dmg` | `Lattice.dmg` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/scripts/release/create_dmg.sh` | 26 | `-volname "ExifEditMac"` | `-volname "Lattice"` |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/RELEASE.md` | 37, 41 | docs mention `ExifEditMac` artifacts | update docs to `Lattice` artifact names (or note internal scheme remains `ExifEditMac`) |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/RELEASE_NOTES_v1.0.0.md` | 1 | heading `ExifEditMac` | update product naming |
| `/Users/chrislemarquand/Documents/Photography/Exifedit/dist/Logbook.app` | path + plist | legacy artifact folder | regenerate dist as `Lattice.app` |

## 5) Compatibility Decisions (Locked)

### UserDefaults Migration
- On first launch after rename, migrate old `Logbook.*` keys to `Lattice.*` keys.
- Keep old keys readable for one transitional release as fallback.
- Set a migration sentinel key: `Lattice.Migration.v1Completed = true`.

### App Support Directory Migration
- If `Lattice` support folder is absent and legacy `Logbook` folder exists:
  - move directory atomically when possible;
  - if move fails, keep legacy path as read fallback and write new data to `Lattice`.
- Log migration result at info level for support diagnostics.

### Module Stability
- Keep `ExifEditCore`, `ExifEditMac`, and package target names unchanged in first rename pass unless explicitly requested.

## 6) Acceptance Criteria

### Branding/Naming Phase
- Finalist list contains 8-12 names that pass all hard constraints.
- Top candidate is pronounceable, distinct, and aligned with native utility positioning.
- Icon routes are legible at 16/32/64 px and maintain motif coherence in monochrome.
- Visual language feels macOS-native, not generic SaaS or glossy novelty.

### Future Rename Execution Phase
- App launches with new name/icon without crashes.
- Existing split-view and preference defaults are retained post-migration.
- Existing app-support data and backups remain accessible.
- Release scripts output renamed app/zip/dmg artifacts successfully.
- Existing tests pass; no new warnings introduced.

## 7) Assumptions
- Trademark/App Store checks are deferred until final name selection (before code rename).
- Native feel follows Apple HIG interaction quality, not Apple trademark mimicry.
- No source rename is applied in this document; this file is the implementation blueprint.
