# Canon EOS Link Software ES-E1 (EOS-1V Remote + EOS-1V Memory) — Settings Reconstruction

Reconstructed from the Mac OS 9 Instruction Manual PDF. Organized by application → window/dialog → tab/sub-tab → option, in the order the manual presents them. This is intended as a spec for recreating the UI/options in a new app.

---

# App 1: EOS-1V Remote

Top-level window **"EOS-1V Remote Menu"**:
- Camera list (box showing connected cameras, e.g. "EOS-1V-01", "EOS-1V-02")
- **Search** button — rescans for connected/data-transfer-mode cameras
- Four action buttons/icons: **Personal Functions**, **Custom Functions**, **Shooting Data**, **Properties**
- Status line: "N camera(s) connected"
- **Exit** button

Menu bar: **File** (Close, Quit) · **Edit** (Cut, Copy, Paste, Clear) · **Help** (About Balloon Help, Show/Hide Balloons)

---

## 1. Personal Functions dialog

Window title: "Personal Functions [camera ID]". Each function (P.Fn) is a checkbox with the function's title text; checking it reveals its sub-options (radio buttons / checkboxes / dropdowns / numeric fields), indented beneath. A function disabled on the camera itself shows as an indeterminate "–" checkbox.

**Tabs:** Exposure Functions 1 · Exposure Functions 2 · Exposure Functions 3 · AF Functions · Film Transport Functions · Other Functions 1 · Other Functions 2 · Combination

**Common buttons:** Load Settings · Reset · OK · Cancel · Apply (Combination tab additionally: Open · Save · Save As...)

### Tab: Exposure Functions 1

- **P.Fn-1 — Disables unwanted shooting mode(s)** (checkbox to enable, then sub-checkboxes; at least one shooting mode must stay enabled)
  - Disables program AE
  - Disables shutter-speed-priority AE
  - Disables aperture-priority AE
  - Disables depth-of-field AE
  - Disables manual exposure
  - Disables bulb exposure
- **P.Fn-2 — Disables unwanted metering mode(s)** (checkbox, sub-checkboxes; at least one must stay enabled)
  - Disables evaluative metering
  - Disables partial metering
  - Disables spot metering
  - Disables centerweighted averaging metering

### Tab: Exposure Functions 2

- **P.Fn-3 — Specifies the metering mode for manual exposure** (radio, single-select)
  - Evaluative metering (default) / Partial metering / Spot metering / Centerweighted averaging metering
- **P.Fn-4 — Sets the maximum and minimum shutter speeds to be used**
  - Maximum: dropdown (shutter speed list, e.g. 1/8000…30 sec)
  - Minimum: dropdown (same list)
- **P.Fn-5 — Sets the maximum and minimum apertures to be used**
  - Minimum (largest aperture, e.g. f/1.0): dropdown
  - Maximum (smallest aperture, e.g. f/91): dropdown

### Tab: Exposure Functions 3

- **P.Fn-6 — Registers and switches the shooting mode and metering mode** (checkbox only; preset via camera body procedure — pressing exposure-comp then multi-control button)
- **P.Fn-7 — Repeats AEB during continuous shooting** (checkbox)
- **P.Fn-8 — Sets AEB only for the first two frames** (checkbox)
- **P.Fn-9 — Changes the AEB sequence for C.Fn-9-2/3 to overexposure, correct exposure, underexposure** (checkbox)
- **P.Fn-10 — Maintains the shift amount for program shift** (checkbox)
- **P.Fn-11 — Prevents cancellation of multiple exposures** (checkbox)

### Tab: AF Functions

- **P.Fn-12 — Changes the sensitivity of AI Servo AF's subject tracking characteristics**
  - Sensitivity: dropdown, 5 levels (Slow ↔ Standard ↔ Fast, e.g. "Slightly fast")
- **P.Fn-13 — Executes AI Servo AF continuous shooting according to the film advance speed** (checkbox)
- **P.Fn-14 — Disables focus detection (search driving) by the lens drive** (checkbox)
- **P.Fn-15 — Disables the AF-assist beam from being emitted** (checkbox)
- **P.Fn-16 — Enables automatic shutter release when focus is achieved at the fixed focusing point while the shutter button is pressed completely** (checkbox)
- **P.Fn-17 — Disables automatic focusing point selection** (checkbox)
- **P.Fn-18 — Enables automatic focusing point selection when C.Fn-11-2 has been set** (checkbox; overridden by P.Fn-17 if both set)

### Tab: Film Transport Functions

- **P.Fn-19 — Sets the film advance mode's continuous shooting speed with Power Drive Booster**
  - Ultra-high-speed continuous: numeric, 8–10 f/sec
  - High-speed continuous: numeric, 4–7 f/sec
  - Low-speed continuous: numeric, 1–3 f/sec
- **P.Fn-20 — Limits the number of frames exposed during continuous shooting**
  - Number of frames: numeric, 2–36
- **P.Fn-21 — Enables silent (low speed) film advance when the shutter button is OFF after shooting** (checkbox)
- **P.Fn-22 — Disables the shutter release when film has not been loaded** (checkbox)

### Tab: Other Functions 1

- **P.Fn-23 — Changes the button's activation hold time after it is pressed**
  - 6 sec. Timer: numeric, 0–3600 sec
  - 16 sec. Timer: numeric, 0–3600 sec
  - Post-shutter-release (2 sec.) Timer: numeric, 0–3600 sec
- **P.Fn-24 — Prevents the LCD panel illumination from turning off during bulb exposures** (checkbox)
- **P.Fn-25 — Changes the default settings implemented when the CLEAR button is ON**
  - Shooting mode: dropdown (e.g. Program AE)
  - Metering mode: dropdown (e.g. Evaluative)
  - Film advance mode: dropdown (e.g. Single-frame)
  - AF mode: dropdown (e.g. AI Servo AF)
  - Focusing point selection: dropdown (e.g. Automatic)

### Tab: Other Functions 2

- **P.Fn-26 — Shortens the shutter release time lag** (checkbox)
- **P.Fn-27 — Enables the electronic dial's function to be used in the reverse direction** (radio, single-select)
  - Main Dial only / Quick Control Dial only / Both dials
- **P.Fn-28 — Prevents exposure compensation with the Quick Control Dial** (checkbox)
- **P.Fn-29 — Displays a warning when there is only limited memory to store shooting data for a user-selectable number of film rolls**
  - Number of rolls remaining when warning is shown: numeric, 1–20
- **P.Fn-30 — Changes the imprinting density of the film ID** (radio, single-select)
  - Dark (default) / Light

### Tab: Combination (view/save/load applied settings)

- Read-only scrollable list of all currently-set P.Fn options and their values, with an "applied to camera / not applied" status line.
- Buttons: **Open**, **Save**, **Save As...** (default folder "PFn Combination", file extension `.PFC`), **Load Settings**, **Reset**, **OK/Cancel/Apply**.

### Enabling/disabling P.Fn on the camera body (no software)
1. Press `<M.Fn>` repeatedly until the `#` icon appears (Personal Function mode).
2. Turn Main Dial to select the P.Fn number (only functions already set are shown).
3. Press `<C.Fn>` button to toggle 0 (disable) / 1 (enable); `<CLEAR>` disables all at once.
4. Press shutter button halfway to confirm.

---

## 2. Custom Functions dialog

Window title: "Custom Function [camera ID]".

**Top control:** Custom Function group dropdown — `0 (Current C.Fn settings of the camera)`, `1`, `2`, `3`.

**Tabs:** Exposure Functions 1 · Exposure Functions 2 · AF Functions 1 · AF Functions 2 · Film Transport Functions · Flash Functions · Other Functions · Combination

**Function → tab mapping:**
- Exposure Functions: C.Fn-3, C.Fn-5, C.Fn-6, C.Fn-9, C.Fn-16
- AF Functions: C.Fn-4, C.Fn-10, C.Fn-11, C.Fn-13, C.Fn-17, C.Fn-18
- Film Transport Functions: C.Fn-1, C.Fn-2, C.Fn-8
- Flash Functions: C.Fn-14, C.Fn-15
- Other Functions: C.Fn-7, C.Fn-12, C.Fn-19

**Common controls:** a row of 19 numbered boxes showing each C.Fn's current setting value (0–3); **Load Settings**, **Copy C.Fn**, **Paste C.Fn**, **Reset C.Fn**; **OK/Cancel/Apply** (Combination tab adds **Open/Save/Save As...**).

Each C.Fn is presented as a dropdown/option table with numbered choices (0, 1, 2, 3…), where 0 is always the camera default/disabled state.

### Tab: Exposure Functions 1

- **C.Fn-3 — DX-coded film speed setting method**
  0. ISO DX (default/enabled) 1. ISO M (manually set film speed)
- **C.Fn-5 — Main Dial / Quick Control Dial function for Tv/Av**
  0. Main Dial→Tv, QCD→Av (default) 1. Main Dial→Av, QCD→Tv 2. Same as 0, but aperture settable with lens detached 3. Same as 1, but aperture settable with lens detached

### Tab: Exposure Functions 2

- **C.Fn-6 — Exposure level increments**
  0. 1/3-stop (default) 1. 1-stop exposure / 1/3-stop compensation 2. 1/2-stop
- **C.Fn-9 — AEB sequence & auto-cancellation**
  0. Sequence O,−,+ / cancels after lens change, film load, Main Switch off (default)
  1. Sequence O,−,+ / does not cancel
  2. Sequence −,O,+ / cancels
  3. Sequence −,O,+ / does not cancel
  (O = correct exposure, − = under, + = over)
- **C.Fn-16 — Safety shift**
  0. Disabled (default) 1. Enabled (for Tv and Av modes)

### Tab: AF Functions 1

- **C.Fn-4 — AF activation / AE lock button functions**
  0. Shutter button = AF start, AE-lock button = AE lock (default)
  1. AE-lock button = AF start, Shutter button = AE lock
  2. Shutter button = AF start, AE-lock button = AF lock (disabled)
  3. AE-lock button = AF start/stop toggle, Shutter button = disabled (real-time AE)
- **C.Fn-11 — Focusing point selection method**
  0. Standard (default) 1. Reverses multi-control button and exposure-comp button functions 2. Quick Control Dial alone selects horizontal focusing point while metering active; multi-control+Main Dial for vertical 3. Reverses multi-control button and FEL button functions
- **C.Fn-18 — Switchover to the registered focusing point**
  0. Disabled/standard (default) 1. AF-point-select button alone switches to registered focusing point 2. Switchover only while AF-point-select button is pressed

### Tab: AF Functions 2

- **C.Fn-10 — Focusing point flashing when focus achieved**
  0. Enabled/normal flashing (default) 1. Disabled (no flashing) 2. Enabled, no dim flashing 3. Bright flashing
- **C.Fn-13 — Focusing point selection limit & spot-metering linkage**
  0. 45 points / center focusing point, no linkage (default)
  1. 11 points / spot metering linked to active focusing point
  2. 11 points / spot metering linked to center focusing point
  3. 9 points / spot metering linked to active focusing point
- **C.Fn-17 — Focusing point activation area**
  0. 1 point / standard (default) 1. 1 + adjacent points (7 total) 2. Automatic expansion (1/7/13 points based on lens/AF mode/subject speed)

### Tab: Film Transport Functions

- **C.Fn-1 — Auto film rewind mode**
  0. High-speed rewind, enabled (default) 1. High-speed rewind, disabled (manual rewind via button) 2. Silent rewind, enabled 3. Silent rewind, disabled
- **C.Fn-2 — Film leader position after rewind**
  0. Rewinds leader into cartridge (default) 1. Leaves leader outside cartridge
- **C.Fn-8 — Frame counter sequence**
  0. Counts up (default) 1. Counts down (remaining frames) 2. F / 9-0 display (EOS-1N style)

### Tab: Flash Functions

- **C.Fn-14 — Automatic reduction of fill-flash output**
  0. Enabled (default) 1. Disabled
- **C.Fn-15 — Shutter curtain synchronization**
  0. 1st-curtain sync (default) 1. 2nd-curtain sync

### Tab: Other Functions

- **C.Fn-7 — USM lens electronic manual focusing**
  0. Enabled after focus achieved; with C.Fn-4-1/3 also enabled before focus achieved (default)
  1. Disabled generally; with C.Fn-4-1/3 enabled before focus achieved
  2. Always disabled, even with C.Fn-4-1/3
- **C.Fn-12 — Mirror lockup**
  0. Disabled (default) 1. Enabled
- **C.Fn-19 — Lens AF-stop button function switching**
  0. AF stop (default) 1. AF start 2. AE lock (while metering active) 3. Automatic focusing-point selection while pressed (hold for center point) 4. Toggle One-Shot AF ↔ AI Servo AF while pressed 5. Turns on Image Stabilizer while pressed

### Tab: Combination (view/save/load applied settings)

- Read-only scrollable list of current C.Fn settings and values, applied/not-applied status.
- Buttons: **Open**, **Save**, **Save As...** (default folder "CFn Combination", extension `.CFC`), **Load Settings**, **Copy C.Fn**, **Paste C.Fn**, **Reset C.Fn**, **OK/Cancel/Apply**.

### Using Custom Function groups on the camera body (no software)
1. `<M.Fn>` until `#` icon (Personal Function mode) → turn dial to **P.Fn-0**.
2. Press `<C.Fn>` to cycle Custom Function group 0→1→2→3 (unregistered groups blink).
3. Press shutter button halfway to confirm.

---

## 3. Shooting Data dialog

Window title: "Shooting Data". Two tabs: **Data Processing** and **Shooting Data Items to be Recorded**.

### Tab: Data Processing
- Display: Camera ID, "Film data exists for N roll(s)"
- Radio buttons (choose one):
  - Load shooting data (downloads to computer, retained on camera)
  - Delete shooting data after loading (downloads, then deletes from camera; confirmation prompt)
  - Delete without loading (deletes from camera without downloading; confirmation prompt)
- Checkbox: Activates EOS-1V Memory after loading shooting data
- Buttons: **Execute**, **Close**

### Tab: Shooting Data Items to be Recorded
- Display: "Film rolls currently recorded: N", "Recordable film rolls remaining: Approx. N"
- Checkboxes (16 selectable items; max 28 bytes/frame budget, some items dim out once budget exceeded):
  - Focal length (2 bytes)
  - Maximum aperture (1 byte)
  - Aperture (1 byte)
  - Manually-set ISO film speed (1 byte)
  - Exposure compensation amount (1 byte)
  - Flash exposure compensation amount (1 byte)
  - Flash mode (1 byte)
  - Metering mode (1 byte)
  - Film advance mode (1 byte)
  - Date (3 bytes)
  - Time (3 bytes, default OFF)
  - AF mode (1 byte) — parent, with nested sub-item:
    - Focusing point(s) achieving focus (7 bytes, requires AF mode checked)
  - Shutter speed (1 byte) — parent, with nested sub-item:
    - Bulb exposure time (2 bytes, requires shutter speed checked)
  - Custom Function settings (11 bytes)
  - Focusing point selection (1 byte)
  - Battery-loaded date and time (6 bytes)
- Always recorded regardless of selection (not shown as options): Film ID, film-loaded date/time, DX-coded film speed, frame No., picture-taking mode, multiple-exposure count.
- Buttons: **Execute**, **Close**

### Description / valid ranges of shooting data items
| Item | Range |
|---|---|
| Focal Length | lens-reported, incl. zoom intermediate values; 0mm if unrecognized |
| Max. Aperture | f/1.0 – f/91 |
| Aperture | f/1.0 – f/91 |
| Manually-Set ISO Speed | ISO 6 – 6400 |
| Exposure Compensation | −6.0 to +6.0 stops (per-frame for AEB) |
| Flash Exposure Compensation | −6.0 to +6.0 stops (per-frame for FEB) |
| Flash Mode | E-TTL/A-TTL/TTL autoflash, manual flash, or off |
| Metering Mode | evaluative / partial / spot / centerweighted averaging |
| Film Advance Mode | single-frame, continuous (low/high/ultra-high speed), 2- or 10-sec self-timer |
| Date | year 2000–2099 |
| Time | hour/min/sec |
| AF Mode | One-Shot AF / AI Servo AF / manual focus |
| Focusing Point(s) Achieving Focus | One-Shot AF only |
| Shutter Speed | 30 sec – 1/8000 sec |
| Bulb Exposure Time | 1 sec – 18 hours |
| Custom Function Settings | full C.Fn set |
| Focusing Point Selection | manual (+ which point) or automatic |
| Battery-Loaded Date and Time | year 2000–2099, h/m/s |

---

## 4. Properties dialog

Window title: "Properties". Two tabs: **Information** and **Date and Time**. Common buttons: **OK**, **Cancel**, **Apply**.

### Tab: Information
- Model name (read-only, e.g. "EOS-1V")
- User-settable No.: editable 2-digit text field

### Tab: Date and Time
- Read-only summary: current camera Date / Time (or "Not set")
- Radio buttons (choose one):
  - Do not change camera date and time settings
  - Copy computer's date and time settings to camera
  - Set date and time manually — reveals:
    - Date: stepper field (year starts at 2000)
    - Time: stepper field

### Setting date/time on the camera body directly (no software)
1. `<M.Fn>` repeatedly to cycle Film ID → Date setting → Personal Function (PF-3) → Data transfer (PC) → back; stop at Date setting.
2. Press the small SET-type button to move through year → month → day → hour → minute; turn Main Dial to set each value.
3. Press shutter button halfway to confirm (seconds reset to 0).
- Note: date/time backup lasts ~24 hrs after battery removal before it needs resetting.

---

# App 2: EOS-1V Memory

A separate bundled Mac app for organizing, viewing, editing, searching, printing, and exporting downloaded shooting data.

**Main window regions:** Title bar · Main toolbar · Folder tree (Unsorted Data / Search Results / user folders) · Film List · Frame List toolbar · Frame List (hideable) · Status bar.

**Main toolbar icons:** Film List — List view / Thumbnails view; Frame List view group (4 icons, see below); Print; Print Preview; Find; New Folder; "Launch EOS-1V Remote" (download) icon.

## Menu bar (main window)

**Data menu**
- Load Shooting Data… (⌘L)
- New Film Data Record… (⌘N)
- Open ▸ (Film Data Edit Window)
- Export ▸ CSV…
- Folder ▸ New Folder / Rename / Delete
- Page Setup…
- Print… (⌘P) ▸ Film List / Frame List / Frame List with Thumbnails / Frame List without Thumbnails
- Print Preview… (⇧⌘P) ▸ same four options
- Quit (⌘Q)

**Edit menu**
- Cut (⌘X) · Copy (⌘C) · Paste (⌘V) · Clear · Delete (⌘D) · Select All (⌘A) · Find (⌘F)

**View menu**
- Choose Frame Data Items Displayed… (⌘H)
- Film List View ▸ List / Thumbnails
- Frame List View ▸ List / Details without Thumbnails / Details / Thumbnails / Not Displayed (default)
- Toolbar (⌘T) — show/hide toggle
- Status Bar (⌘B) — show/hide toggle

**Help menu**
- About Balloon Help
- Show Balloons / Hide Balloons

## Folder tree / organizing data
- Fixed folders: **EOS-1V Memory** (root), **Unsorted Data**, **Search Results** (cannot rename/delete/create-under).
- User folders: create/rename/delete via toolbar, Data/Folder menu, or control-click context menu (Help / New Folder / Rename / Delete); can be nested; drag-and-drop to move film records or folders; same-level siblings can't share a name; non-empty folders can't be deleted.
- **Create New Folder** dialog: "New Folder Name:" text field (default "New Folder"); Cancel / OK.

## Changing the view

### Film List View
- **List** (default): columns — Film ID, Title, Film-loaded date, Film-loaded time, Frame count, ISO (DX), Remarks (columns resizable, clickable-header sort asc/desc)
- **Thumbnails**: thumbnail image + Film ID + Title

### Frame List View
- **List** — text-only list
- **Details without Thumbnails** — all shooting data fields, no images
- **Details** — all shooting data fields + thumbnails (drop-shadow = multiple exposure)
- **Thumbnails** — thumbnail + frame No. + focal length + aperture (Av) + shutter speed (Tv)
- **Not Displayed** (default) — Frame List hidden

Frame List toolbar: view-mode icons (4) + Go to 1st / Go to Previous / Go to Next / Go to Last.

## Choose Frame Data Items Displayed dialog (⌘H)
Two tabs: **List View**, **Detailed View**. Each: dual-listbox chooser (Not displayed ↔ Displayed) with **Add >>**, **<< Delete**, **Move Up**, **Move Down**, **Reset**; bottom checkboxes (Detailed View tab): "Focusing point selection/achieving focus", "Custom Function", "Remarks"; **Cancel/OK**.
Selectable items include: Focal Length, Max. aperture, Tv, Av, ISO (M), Exposure compensation, Flash exposure compensation, Flash mode, Metering mode, Shooting mode, Film advance mode, AF mode, Frame No., Film ID, Film-loaded date/time, ISO (DX), Custom Function, Bulb exposure time, Date, Time, Multiple exposures, Battery-loaded date/time, Remarks.
Note: main-window and Film Data-Editing-window Frame List display settings are independent of each other.

## Editing shooting data

### Film record operations (main window)
- **New Film Data Record** (⌘N): creates blank 36-exposure roll record, opens Film Data-Editing window.
- **Delete**: select + ⌘D or context menu; confirms "Delete selected film data?" (Yes/No); irreversible.
- **Select multiple**: shift-click range, ⌘-click discontiguous, ⌘A select-all.

### Film Data-Editing window (double-click a film record)
Fields: Film ID (read-only) · Frames in first row (1–6, numeric) · Frames per row (4–6, numeric) · Title (≤63 chars) · Date and time film loaded · Frame count (read-only, only non-editable field) · ISO (DX) · Remarks (≤255 chars) · Thumbnail image well.
Own menu bar:
- **Data**: Save (⌘S) · Save As New Film Data (⇧⌘S) · Edit Frame Data (⌘E) · Thumbnail ▸ (Select Image / Delete / Update / Open Original) · Close (⌘W)
- **Edit**: Cut/Copy/Paste/Clear/Delete(⌘D)/Select All(⌘A)/Insert New Frame Data(⌘I)/Insert Copied Frame Data
- **View**: Choose Frame Data Items Displayed… (⌘H, independent of main window) · Frame List View ▸ (List/Details w/o Thumbnails/Details/Thumbnails) · Toolbar(⌘T) · Status Bar(⌘B)
- **Help**: About Balloon Help · Show/Hide Balloons

Toolbar: Save, Cut, Copy, Paste. Frame List mini-toolbar: view modes, Edit Frame Data, Go to 1st/Previous/Next/Last.

**Thumbnails**: created from PICT/BMP/JPEG/TIFF source files via Select Image (standard Open dialog with Hide Preview/Cancel/Open); Delete, Update, Open Original also available; multi-select images assigns thumbnails alphabetically; option-drag copies a thumbnail to another frame.

**Duplicating/inserting/deleting frame records**: Copy/Cut + Paste across film windows (replaced frames marked with `*`); Insert Copied Frame Data (numbered "Frame No. 0"); Insert New Frame Data (⌘I); Delete (⌘D, also removes thumbnail in Thumbnails view); multi-select via shift/⌘-click.

### Frame Data-Editing window ("Frame Data Edit" dialog, double-click a frame)
- Thumbnail preview + Image file path (read-only) + **Select Image…** button
- Frame No. (numeric, checkbox)
- Date (checkbox + stepper)
- Time (checkbox + stepper)
- Lens: Focal Length (field+stepper) · Max. aperture (dropdown+stepper)
- Shooting information: Tv, Exposure compensation, Metering mode, AF mode, Flash mode (left column) · Av, Flash exposure compensation, Shooting mode, Film advance mode, Multiple exposures (right column) — all dropdowns
- Remarks (multi-line text, ≤255 chars, no line breaks)
- Buttons: Cancel, OK
- Modified frames marked with `*` in list views (thumbnail/Remarks changes excluded from the mark).

## Search / Find dialog (Edit/Find, ⌘F)
Up to 5 criteria rows, each:
- Multiple criteria (rows 2–5): blank / AND / OR / NOT
- Search item: dropdown of any shooting-data field (User-settable No., Film No., ISO(DX), Frame No., Focal length, Max. aperture, Tv, Av, ISO(M), Exposure compensation, Flash exposure compensation, Flash mode, Metering mode, Shooting mode, Film advance mode, AF mode, Date, Time, Multiple exposures, Remarks, etc.)
- Value: text field or dropdown (type-dependent)
- Search criteria: **Greater than or equal to** / **Less than or equal to** / **Equal to** / **Not equal to** / **Data available** / **Data not available**

Options: ☐ Ignore case (Remarks search) · ☐ Search all folders (else current folder only)
Buttons: Cancel, OK — results populate the Search Results folder; status bar shows match count/location.

## Printing
Data/Print (⌘P) or Print Preview (⇧⌘P), each with submenu: Film List / Frame List / Frame List with Thumbnails / Frame List without Thumbnails. Only one frame record can't be printed at a time via the frame editor — print operates on the currently displayed/selected list.
- **Page Setup** dialog (printer-driver-dependent): Paper Size, Banner Printing checkbox, Scale %, Orientation (Portrait/Landscape), Save Settings checkbox, Custom/Utilities buttons, OK/Cancel.
- **Print** dialog (printer-driver-dependent): Copies, Pages (All / From-To), BJ Cartridge, Print Mode (+Details), Media Type, Options, Paper Feed, Apply, Print Greyscale checkbox, Print Preview button, Print/Cancel.
- **Print Preview** window: Next/Previous Page, Zoom In/Out, Print…, Margins (drag column-width handles), Close.

## Exporting (CSV)
Data/Export/CSV… → Save As dialog (default folder "CSV Data", filename default "Untitled.CSV", New/Cancel/Save). Output layout: line 1 = film data (excl. Remarks); line 2 = Remarks; blank line; line 3 = frame-data column headers; line 4+ = frame data rows.

## Downloading shooting data (bridges to EOS-1V Remote)
1. Click the EOS-1V Remote launch icon on the toolbar → message dialog "Put the camera in data-transfer mode and connect the ES connecting cable. Click OK to start EOS-1V Remote..." with "Don't display this message again" checkbox + OK.
2. In EOS-1V Remote Menu, click **Shooting Data** → opens the Shooting Data dialog (Data Processing / Shooting Data Items to be Recorded tabs — see App 1 §3 above).
3. Exit EOS-1V Remote to return to EOS-1V Memory.

## Mac ↔ Windows shooting-data compatibility
- Data lives in the **DATA** folder inside **EOS LINK ES-E1** (sibling folders: CFn Combination, EOS-1V Memory, EOS-1V Remote, Installation Guide, Instruction Manual, PFn Combination, USER).
- Each film record = one `.EFD` file (e.g. `FI000000.EFD`); transfer whole folders (not loose `.EFD` files) via DOS-formatted floppy/removable media.
- Windows default path: `C:\Program Files\Canon\EOS LINK ES-E1\DATA`. Same-name files get overwritten on transfer — rename first or use the app's transfer flow instead of raw copy.

---

## Notes on completeness
- All 30 Personal Functions (P.Fn-1–30) and all 19 Custom Functions (C.Fn-1–19, non-sequential numbering with no C.Fn-20+) are covered.
- Shooting Data's 16 selectable recorded-item checkboxes and Properties' two tabs are fully covered.
- EOS-1V Memory's full menu structure, view options, editing windows, search, print, export, and download bridge are covered.
- Where the manual's dropdown lists were long standard ranges (e.g. full shutter-speed table 30 sec–1/8000 sec, full aperture table f/1.0–f/91), the useful endpoints/increments are given rather than every discrete stop, since these are standard photographic value tables.
