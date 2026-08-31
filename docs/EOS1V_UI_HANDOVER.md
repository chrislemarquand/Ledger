# EOS-1V UI implementation handover

## Status

This work is **not ready to merge**. The EOS-1V device UI, USB discovery, and read-only Python bridge are substantially implemented, but switching from the EOS-1V sidebar item back to a normal folder leaves the visible browser and breadcrumb bar stale.

The important symptom is that the sidebar selection, sidebar count, and window title/subtitle are correct while the centre browser and path bar show state from an older folder. This means the `AppModel` selection is changing, but the visible `BrowserContainerViewController` is no longer rendering the corresponding model state.

No commits were created. Both repositories have working-tree changes.

## Repositories and branches

- Ledger: `/Users/chrislemarquand/Xcode Projects/Ledger`
  - Branch at the start of the work: `eos1v-poc`
- Python implementation: `/Users/chrislemarquand/Xcode Projects/eos1v-serial`
  - Branch at the start of the work: `master`
  - Existing untracked `captures/` belongs to the user and has not been modified or removed.

## Product requirements used

- Ledger is an AppKit application. The main EOS-1V UI added here is native AppKit, not SwiftUI.
- Detect the Canon ES-E1 USB cable (`VID 0x04A9`, `PID 0x3040`).
- While the cable is present, show a `Devices` sidebar section between Sources and Recents containing `Canon EOS-1V`.
- Selecting the device shows the Figma-inspired Connect, Personal, Custom, Shooting, and Properties interface.
- Search/download and all camera interaction must use `eos1v-serial`; Ledger must not implement the camera protocol independently.
- Access is read-only for now, while leaving a deliberate policy boundary for future write support.
- While the device is selected, normal browser toolbar actions are disabled and the inspector is collapsed with its toggle disabled.
- Camera art must use the existing asset:
  `Sources/Ledger/Assets.xcassets/EOS1VBody.imageset`.

The supplied Figma references were these nodes in file `4dtLVt8iqHLr6b8R1x4LOy`:

- `2:2098`
- `2:2337`
- `3:2817`
- `2:2651`
- `19:619`
- `19:896`

The user also supplied screenshots of the six intended Connect states: cable connected, searching, not found, connected, downloading, and data loaded.

## Ledger changes

### New files

#### `Sources/Ledger/EOS1V/EOS1VDeviceMonitor.swift`

- Polls IOKit for an `IOUSBHostDevice` matching Canon `04A9:3040`.
- Calls `onPresenceChanged` when the cable appears or disappears.
- A one-second polling timer is used rather than an IOKit notification registration.

#### `Sources/Ledger/EOS1V/EOS1VSessionController.swift`

- Defines a typed Swift client for the Python JSON-lines interface.
- Resolves the existing configurable Python/tool locations through the same user-default keys used by the older EOS console implementation.
- Defines read-only operations: `inspect`, `settings`, and `download`.
- Adds an explicit access-policy layer (`read`, `write`, `destructive`) with `.readOnly` currently active.
- Models Connect state as:
  - cable connected
  - searching
  - not found
  - connected
  - downloading
  - loaded
  - failed
- Parses downloaded CSV rows for the Shooting tab.
- Saves downloads under Ledger's Application Support directory unless an EOS output directory has been configured.
- Search caches custom/personal settings returned by Python. This avoids launching a second settings process after the shooting-data download.

#### `Sources/Ledger/EOS1V/EOS1VDeviceViewController.swift`

- Native AppKit segmented interface for Connect, Personal, Custom, Shooting, and Properties.
- Uses `NSImage(named: "EOS1VBody")`.
- Implements all six Connect card states from the supplied screenshots.
- Data tabs remain disabled until a successful download.
- Settings/property tables are display-only.
- Includes `EOS1VBackgroundView`, an opaque dynamic window-background view. This was added during the latest routing attempt so the normal browser could remain mounted behind the device screen without showing through it.

### Existing files changed

#### `Sources/Ledger/AppModel.swift`

- Added `SidebarKind.eos1vDevice`.
- Added `isEOS1VCableConnected`.
- Added `lastNonDeviceSidebarID` for disconnect fallback.

#### `Sources/Ledger/LedgerSidebarTypes.swift`

- Added `LedgerSidebarSection.devices`.
- Added the camera symbol for the device item.

#### `Sources/Ledger/AppModel+Sidebar.swift`

- Sidebar order is now Sources, Devices, Pinned, Recents.
- Conditionally creates a stable device item with ID `device-eos1v-es-e1`.
- `setEOS1VCableConnected(_:)` refreshes sidebar composition and falls back to the prior non-device selection if the cable disappears while selected.
- Exhaustive sidebar-kind switches were updated so the device cannot be pinned or treated as a filesystem location.

#### `Sources/Ledger/AppModel+Navigation.swift`

- `selectSidebar(id:)` returns early for `.eos1vDevice` instead of trying to enumerate files.
- Records the most recent non-device sidebar item for disconnect fallback.

#### `Sources/Ledger/AppModel+FileLoading.swift`

- Exhaustive switches were updated for `.eos1vDevice`.
- Device selection has no filesystem URL and enumerates no images.

#### `Sources/Ledger/MainContentView.swift`

- Creates the EOS session controller, device view controller, USB monitor, and a centre-content router.
- Changes the middle pane from the browser controller directly to `MainContentRouterViewController`.
- Routes between the existing browser and the device view based on sidebar selection.
- Updates window title/subtitle for EOS state.
- Collapses the inspector on device entry and attempts to restore its prior state on exit.
- Disables toolbar validation/actions while the device is selected.
- Explicitly disables toolbar item/control state because AppKit validation alone did not visually disable every item.

#### `Sources/Ledger/BrowserContainerViewController.swift`

This file was changed only while trying to repair the regression described below:

- Added `viewWillAppear()` calling `resumeRendering()`.
- Added `resumeRendering()` to reinstall observers and force `render()`.
- Added a guard preventing duplicate observer installation.

These changes did **not** resolve the live regression and should be reassessed rather than assumed correct.

#### `Ledger.xcodeproj/project.pbxproj`

- Adds the three new EOS Swift files to the Ledger target.

## `eos1v-serial` changes

### `eos1v_tool.py`

Added a versioned JSON-lines machine interface:

```text
eos1v_tool.py machine inspect
eos1v_tool.py machine settings
eos1v_tool.py machine download <csv-path> <raw-path>
```

- Schema version is currently `1`.
- Events are `started`, `completed`, and `failed`.
- Stdout is intended to contain machine-readable JSON lines only.
- `inspect` returns camera status, recorded-item layout, and decoded custom/personal settings.
- `settings` returns decoded custom/personal settings.
- `download` delegates to the existing `EOS1V.download()` and existing CSV conversion.
- Unknown operations, including `erase-all`, are rejected by this machine interface.

A live test found that sending the normal F2 teardown at the end of Search caused the next process-based Download to fail because the camera had left transfer mode. The current `_machine_inspect` deliberately does not send F2; it reads settings through existing `EOS1V._read_registers` and then closes the USB transport, leaving the camera ready for the following download process.

### Tests

- Added `tests/test_machine.py`.
- Added it to `tests/run_all.py`.
- Tests cover structured recorded items, canonical setting decoding, JSON-lines events, rejection of unknown/destructive machine operations, and the no-F2 Search session boundary.

## What worked in live testing

- The connected ES-E1 cable was detected from IOKit.
- The Devices section appeared in the correct sidebar location.
- The supplied `EOS1VBody` asset rendered correctly.
- Search successfully reached Connected against the real camera.
- A download completed and displayed `16 films and 554 frames` in the loaded state.
- Personal, Custom, Shooting, and Properties tabs unlocked after loading.
- The device toolbar appeared disabled and the inspector was collapsed.
- Python machine-interface tests pass:

```text
python3 tests/test_machine.py
machine interface tests passed.
```

## Current blocking regression: browser is stale after leaving EOS-1V

### Reproduction

1. Plug in the ES-E1 cable.
2. Select Canon EOS-1V in Devices.
3. Search and/or load camera data.
4. Select any normal folder or Recent item in the sidebar.
5. Select other folders.

### Observed

- Sidebar selection highlight changes correctly.
- Sidebar file count is correct.
- Window title/subtitle changes to the selected folder and correct count.
- The centre browser continues displaying images from an older folder.
- The path bar says `No Folder Selected`, a state the user reports never seeing before this work.
- Further folder changes continue updating selection/title/count but not the visible browser/path bar.

Live verification of the latest attempted fix still showed this mismatch:

- EOS-1V loaded view showed `16 films and 554 frames`.
- Selecting `Ledger Import Test` changed the title to `3 images`, but the centre still showed roughly 24 images from an older folder and the path bar remained `No Folder Selected`.
- Selecting `KP400 06 copy` changed the title to `36 images`, but the path bar still remained `No Folder Selected` and the visible collection did not provide convincing evidence of a fresh render.

Therefore the issue is **not fixed** by the current working tree.

## Attempts made to fix the regression

### Attempt 1: remove and reattach child controllers

The first `MainContentRouterViewController` implementation removed the active child controller from its parent and attached the other controller.

This exposed a concrete lifecycle problem: `BrowserContainerViewController.viewWillDisappear()` calls `renderObservers.removeAll()`, but it previously had no matching reinstall path when reattached. This clearly explains how the browser could become stale.

### Attempt 2: keep both child controllers attached and toggle `isHidden`

The router was changed to install both children once and hide/show their views.

This was insufficient. AppKit appearance handling still appeared to trigger the browser teardown path, or the explicit return path did not restore the browser's effective subscriptions/rendering.

### Attempt 3: leave the browser mounted behind the device and explicitly resume it

The current working tree:

- never hides the browser view;
- puts an opaque EOS device view over it;
- hides only the device view when returning to the browser;
- calls `browser.resumeRendering()` on every `showBrowser()`;
- makes `resumeRendering()` install observers if empty and call `render()` immediately.

Despite that, the real app still showed the stale centre collection and `No Folder Selected` path bar after the device-to-folder transition.

## Suggested next investigation

Do not continue layering lifecycle workarounds onto the current router without first instrumenting the state flow.

Recommended approach:

1. Add temporary logging or breakpoints to these exact points:
   - `AppModel.handleExplicitSidebarSelectionChange(to:)`
   - `AppModel.selectSidebar(id:)`
   - entry and completion of `AppModel.loadFiles(for:)`
   - assignments to `browserItems` and `selectedSidebarID`
   - `NativeThreePaneSplitViewController.updateContentDestinationIfNeeded()`
   - `BrowserContainerViewController.installRenderObservers()`
   - `BrowserContainerViewController.viewWillDisappear()`
   - `BrowserContainerViewController.resumeRendering()`
   - `BrowserContainerViewController.render()`
   - `BrowserIconViewController.update(model:items:)`
   - `BrowserContainerViewController.updatePathBarURL()`
2. Confirm whether `loadFiles(for:)` actually assigns the selected folder's URLs after leaving the device.
3. Confirm whether the `model.$browserItems` Combine subscription fires and whether `render()` receives the new count.
4. Check for an older asynchronous folder load completing after the new selection and overwriting `browserItems`. The existing folder-load workflow does extensive task cancellation but does not obviously associate the top-level enumeration result with the currently selected sidebar ID.
5. Check whether replacing the middle pane with a router breaks assumptions elsewhere that `browserController.view` is the actual split-view content view.
6. Consider a safer architecture that does not replace or reparent the existing browser controller at all. For example, keep the original `BrowserContainerViewController` as the split content controller and let it host an EOS overlay, or add an overlay sibling directly in the existing middle pane without changing browser controller ownership/lifecycle.
7. Once the cause is known, remove the speculative `resumeRendering()` changes if they are not part of the real fix.

The strongest architectural recommendation is item 6: preserve the original browser controller's exact parentage and lifecycle, and place the EOS UI over it. The regression began when the middle pane changed from `BrowserContainerViewController` to `MainContentRouterViewController`.

## Build and verification caveat

The current checkout contains pre-existing uses of `NSMenuItem.preferredImageVisibility` guarded for macOS 27 in both Ledger and SharedUI. The installed Xcode is 26.6 and its SDK does not contain that API, so an unmodified command-line build fails before/while compiling those unrelated lines.

For verification only, those pre-existing blocks were temporarily removed, the app was built successfully, and the blocks were immediately restored. The temporary bypass is not present in the working tree.

Successful verification command after that temporary bypass:

```text
xcodebuild -project Ledger.xcodeproj \
  -scheme Ledger \
  -configuration Debug \
  -destination 'platform=macOS' build
```

The new EOS AppKit files also passed direct Swift 6 type-checking.

## Current working-tree files

Ledger currently has modifications/additions in:

```text
Ledger.xcodeproj/project.pbxproj
Sources/Ledger/AppModel+FileLoading.swift
Sources/Ledger/AppModel+Navigation.swift
Sources/Ledger/AppModel+Sidebar.swift
Sources/Ledger/AppModel.swift
Sources/Ledger/BrowserContainerViewController.swift
Sources/Ledger/LedgerSidebarTypes.swift
Sources/Ledger/MainContentView.swift
Sources/Ledger/EOS1V/EOS1VDeviceMonitor.swift
Sources/Ledger/EOS1V/EOS1VDeviceViewController.swift
Sources/Ledger/EOS1V/EOS1VSessionController.swift
```

`eos1v-serial` currently has:

```text
eos1v_tool.py
tests/run_all.py
tests/test_machine.py
captures/  # pre-existing untracked user data; preserve
```

## Cleanup note

A separately launched DerivedData test instance of Ledger may still be running from manual verification. Its executable path is under:

```text
/Users/chrislemarquand/Library/Developer/Xcode/DerivedData/Ledger-gpvdfwrxzfsbpfcfujoiqbfvxrij/Build/Products/Debug/Ledger.app
```

Do not terminate other Ledger processes launched by Xcode without checking their executable path first.
