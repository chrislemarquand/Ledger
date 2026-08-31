# NOTICE

Ledger bundles, links against, or depends on the following third-party
software. Each remains under its own license; nothing here changes or
supersedes those terms.

## ExifTool

Bundled directly into the app's resources (`exiftool/bin/exiftool`, see
`scripts/build/bundle_exiftool.sh`) and used for all metadata reading and
writing. Currently pinned to version 13.50 (`Config/Base.xcconfig`,
`EXIFTOOL_REQUIRED_VERSION`).

- **Author**: Phil Harvey
- **License**: same terms as Perl itself — the Perl Artistic License or the
  GNU General Public License, at the licensee's option
- **Homepage**: https://exiftool.org/

## Sparkle

Used for in-app update checks and delivery (`SPUUpdater`, `UpdateService.swift`).
Referenced as an Xcode Swift package dependency (`Ledger.xcodeproj`,
minimum version 2.0.0; resolved to 2.9.1 in the shared `SharedUI.xcworkspace`
build environment).

- **License**: MIT
- **Homepage**: https://github.com/sparkle-project/Sparkle

## WhatsNewKit

Used for the Welcome/What's New screen (`AppWelcomeViewController`, via
SharedUI). Pinned in `Package.resolved` at version 2.2.1.

- **Author**: Sven Tiigi
- **License**: MIT
- **Homepage**: https://github.com/SvenTiigi/WhatsNewKit

## eos1v-serial

Ledger's EOS-1V device connection feature (Connect/Shooting Data/Date and
Time tabs) works by driving `eos1v_tool.py` as a subprocess. That tool was
originally downloaded from a third party and is not Ledger's own work; it
now lives as a git submodule at `External/eos1v-serial`, pointing at a
private copy (`chrislemarquand/eos1v-serial`) with local modifications
(a `machine` JSON subprocess interface and a reviewed `set-clock` write
operation) layered on top for use as a Ledger dependency — not a GitHub
fork, no live link back to the original.

- **Original author/repository**: https://github.com/epvucclaude/eos1v-serial
- All credit for the original Canon EOS-1V protocol reverse-engineering
  work belongs there; see that repository's own README for the author's
  account of how it was derived.
