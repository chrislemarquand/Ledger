# Bundling the EOS-1V Python tool

Ledger talks to a real EOS-1V camera via the pinned `External/eos1v-serial/eos1v_tool.py`
(a git submodule). For a build to work on any machine that downloads the app — not just
a developer's own checkout with a hand-built `.venv` — that script is frozen into a
self-contained executable with [PyInstaller](https://pyinstaller.org/) and bundled into
`Ledger.app/Contents/Resources/eos1v-tool/`, the same way `scripts/build/bundle_exiftool.sh`
already bundles ExifTool. See that script's own header comment for the general rationale
(`alwaysOutOfDate` build phase, vendored payload not statically declarable as build inputs).

**`Ledger.app` ships arm64-only** (verified against the real built binary, not assumed —
check with `lipo -info Ledger.app/Contents/MacOS/Ledger`). The frozen eos1v-tool must stay
arm64-only too. Do not build this universal2/x86_64 on your own initiative — that's a
decision for the app as a whole to make deliberately, not something to drift into here.

## How the pieces fit together

- `Vendor/eos1v-tool/build/` — the frozen PyInstaller `--onedir` output (gitignored, like
  `Vendor/exiftool/` — nothing here is committed; every developer/CI machine builds or
  fetches its own copy before building the app).
- `Vendor/eos1v-tool/BUILD_INFO.json` — provenance record (submodule commit, pyusb/libusb
  versions, architecture, excluded modules) that `scripts/build/bundle_eos1v_tool.sh` and
  `scripts/release/archive.sh` both check against `Config/Base.xcconfig`'s
  `EOS1V_TOOL_REQUIRED_SUBMODULE_COMMIT` before trusting the vendored build — the same
  staleness protection ExifTool's version pin gives it.
- `Licenses/libusb-LGPL-2.1.txt` — tracked in git (unlike `Vendor/`, this must survive a
  vendor wipe): libusb is LGPL-2.1, and the bundle script copies this into
  `Resources/eos1v-tool/LICENSE-libusb-LGPL-2.1.txt` on every build. Don't remove it or the
  copy step in `bundle_eos1v_tool.sh` without understanding why it's there.
- `Sources/Ledger/EOS1V/EOS1VSessionController.swift`'s `resolvedInvocation()` — looks up
  `Bundle.main.resourceURL?.appendingPathComponent("eos1v-tool/bin/eos1v_tool")` first,
  falling back to a `UserDefaults`-gated dev override (`<prefix>.eos1v.toolDirectory` +
  `<prefix>.eos1v.pythonPath`, both required together) only for local iteration against an
  unfrozen `.venv` without re-freezing on every `eos1v_tool.py` change. The bundled path is
  the only one that ships.

## Rebuilding the vendored tool

Needed whenever `External/eos1v-serial` moves to a new pinned commit, or pyusb/PyInstaller
need updating.

```sh
cd External/eos1v-serial
python3 -m venv .venv   # if you don't already have one
./.venv/bin/pip install pyusb pyinstaller

./.venv/bin/pyinstaller \
  --name eos1v_tool \
  --onedir \
  --exclude-module ssl --exclude-module _ssl --exclude-module hashlib \
  --distpath /tmp/eos1v-freeze/dist \
  --workpath /tmp/eos1v-freeze/build \
  --specpath /tmp/eos1v-freeze \
  --clean --noconfirm \
  eos1v_tool.py

rm -rf ../../Vendor/eos1v-tool/build
cp -R /tmp/eos1v-freeze/dist/eos1v_tool ../../Vendor/eos1v-tool/build
```

Then update `Vendor/eos1v-tool/BUILD_INFO.json` by hand: `submoduleCommit` (must match
`git -C External/eos1v-serial rev-parse HEAD`), `pyusbVersion`
(`./.venv/bin/pip show pyusb`), `pyinstallerVersion`, and confirm `targetArchitecture`
stays `"arm64"`. If you change `EOS1V_TOOL_REQUIRED_SUBMODULE_COMMIT` in
`Config/Base.xcconfig` to match, do that in the same change — the bundle script and
`archive.sh` both fail closed on a mismatch, deliberately.

**Why `--exclude-module ssl,_ssl,hashlib`:** `eos1v_tool.py` never imports any of them
(verified by grepping the source — it only imports `sys, struct, csv, time, json, math,
re` from the standard library, plus `usb.core`/`usb.util` from pyusb). PyInstaller's
default analysis pulls them in transitively anyway, which bundles `libssl.3.dylib` and
`libcrypto.3.dylib` (OpenSSL) for no reason — extra size, extra Mach-O files to sign, and
an OpenSSL license/attribution obligation the app doesn't actually need to take on.
Excluding them dropped the frozen bundle from ~19MB to ~14MB. **Verified safe without any
hardware contact**: run the frozen `eos1v_tool` binary with zero arguments and confirm it
prints its usage docstring cleanly — `eos1v_tool.py`'s own `main()` guarantees this never
reaches any USB code (every subcommand branch requires a specific `sys.argv[1]` match;
the fallback for anything else, including no arguments, is a bare `print(__doc__)`, read
the source yourself before trusting this if the script changes). Never smoke-test a
rebuilt bundle by running an actual `machine` subcommand (`inspect`/`download`/etc.)
without first confirming what's physically connected — the tool will genuinely attempt
USB discovery for those.

## What `libusb` gets bundled, and why no build step is needed for it

PyInstaller's own `hook-usb.py` (from `pyinstaller-hooks-contrib`, installed automatically
as a `pyinstaller` dependency) detects the `usb` import and bundles whatever
`libusb-1.0.dylib` your `pip install pyusb` environment resolves at freeze time (Homebrew's
build, if you have Homebrew's `libusb` installed) into `_internal/libusb-1.0.dylib`
automatically — no explicit step needed, and PyInstaller's runtime bootloader resolves
`_internal/` relative to the frozen executable's own location, which keeps the whole tree
self-contained wherever it's copied (verified: ran the copied bundle from a completely
different directory than where PyInstaller built it, worked identically, no environment
variables needed).

## Signing

`scripts/release/archive.sh`'s existing "sign every Mach-O found anywhere under the app
bundle, by content-sniffing not extension" pass and its separate "re-sign every nested
`.framework`" pass were written generically enough to already cover this without any
changes — they explicitly anticipated "bundled tools... plain executables" in their own
comments before this ever existed. **This has not yet been verified against a real
Developer ID signing + notarization run** (only checked with an ad-hoc identity, which
surfaced a real "different Team IDs" load-time error signing `Python.framework`'s nested
binary standalone — possibly an ad-hoc-signing-specific artifact, not necessarily a real
Developer ID cert issue, but unresolved). Do not consider this release-ready until someone
runs the actual `archive.sh` (real `DEVELOPER_ID_APPLICATION`) followed by
`verify_signature.sh` against a build containing the bundled eos1v-tool, and confirms the
bundled binary actually launches from inside the signed, archived app.

## Testing without a camera

`External/eos1v-serial/eos1v_tool.py`'s `machine inspect`/`download`/etc. all attempt real
USB discovery immediately. To sanity-check a rebuilt bundle without touching any hardware,
invoke it with no arguments (see above) — never invoke a real subcommand unless you've
first confirmed, out loud, what's actually connected.
