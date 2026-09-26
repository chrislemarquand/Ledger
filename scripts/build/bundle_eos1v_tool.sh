#!/bin/sh
set -euo pipefail

# Mirrors bundle_exiftool.sh's own precedent exactly (see that script's header
# comment for the full rationale): always runs (alwaysOutOfDate = 1 in the
# pbxproj script phase), rather than declaring inputs/outputs for Xcode's
# incremental build system, because the payload is a whole vendored PyInstaller
# onedir tree copied wholesale below, whose real inputs aren't statically
# enumerable the way a single source file's are.
#
# arm64-only, deliberately: Ledger.app itself ships arm64-only (verified
# against the real built binary, not assumed) — this must never become
# universal2/x86_64 on its own initiative. If the app gains a real universal2
# requirement, that's a decision to make explicitly and once, not something
# this script should drift into by rebuilding with different flags.
DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/eos1v-tool/bin"
DEST_FILE="${DEST_DIR}/eos1v_tool"
REQUIRED_SUBMODULE_COMMIT="${EOS1V_TOOL_REQUIRED_SUBMODULE_COMMIT:-6dd6f62eb5c28ad89bb65afafbc48780b04f1d40}"

if [ -n "${EOS1V_TOOL_SOURCE_PATH:-}" ] && [ -x "${EOS1V_TOOL_SOURCE_PATH}" ]; then
  SRC="${EOS1V_TOOL_SOURCE_PATH}"
elif [ -x "${SRCROOT}/Vendor/eos1v-tool/build/eos1v_tool" ]; then
  SRC="${SRCROOT}/Vendor/eos1v-tool/build/eos1v_tool"
else
  echo "error: eos1v_tool not found. Place a frozen build in Vendor/eos1v-tool/build/"
  echo "error: (see docs/eos1v-tool-bundling.md) or set EOS1V_TOOL_SOURCE_PATH."
  exit 1
fi

SRC_DIR="$(dirname "${SRC}")"
BUILD_INFO="${SRCROOT}/Vendor/eos1v-tool/BUILD_INFO.json"
INTERNAL_SRC="${SRC_DIR}/_internal"

if [ ! -f "${BUILD_INFO}" ]; then
  echo "error: ${BUILD_INFO} not found. Every vendored eos1v-tool build must record its"
  echo "error: provenance (submodule commit, pyusb/libusb versions, architecture) there."
  exit 1
fi

BUNDLED_COMMIT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['submoduleCommit'])" "${BUILD_INFO}")"
if [ "${BUNDLED_COMMIT}" != "${REQUIRED_SUBMODULE_COMMIT}" ]; then
  echo "error: vendored eos1v-tool was built from External/eos1v-serial commit ${BUNDLED_COMMIT},"
  echo "error: but ${REQUIRED_SUBMODULE_COMMIT} is required. Rebuild the vendored tool against"
  echo "error: the current submodule commit (see docs/eos1v-tool-bundling.md)."
  exit 1
fi

BUNDLED_ARCH="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['targetArchitecture'])" "${BUILD_INFO}")"
if [ "${BUNDLED_ARCH}" != "arm64" ]; then
  echo "error: vendored eos1v-tool records targetArchitecture=${BUNDLED_ARCH}, expected arm64."
  echo "error: this app ships arm64-only; do not bundle a universal2/x86_64 build without a"
  echo "error: deliberate, separate decision to make the whole app universal2 first."
  exit 1
fi

if [ ! -d "${INTERNAL_SRC}" ]; then
  echo "error: ${INTERNAL_SRC} not found alongside ${SRC} — expected a PyInstaller --onedir"
  echo "error: layout (executable plus an _internal/ support directory)."
  exit 1
fi

mkdir -p "${DEST_DIR}"
cp "${SRC}" "${DEST_FILE}"
chmod 755 "${DEST_FILE}"
rm -rf "${DEST_DIR}/_internal"
cp -R "${INTERNAL_SRC}" "${DEST_DIR}/_internal"

# libusb is LGPL-2.1: the distributed binary must carry the license text, not
# just link to it from the About panel. Tracked in git (Licenses/, unlike
# Vendor/ which is gitignored build output) so it survives a Vendor/ wipe.
LIBUSB_LICENSE="${SRCROOT}/Licenses/libusb-LGPL-2.1.txt"
if [ ! -f "${LIBUSB_LICENSE}" ]; then
  echo "error: ${LIBUSB_LICENSE} not found. libusb is LGPL-2.1 and its license text must ship with the app."
  exit 1
fi
cp "${LIBUSB_LICENSE}" "${DEST_DIR}/../LICENSE-libusb-LGPL-2.1.txt"

# Every Mach-O file under _internal/ (the interpreter's shared library,
# libusb-1.0.dylib, any compiled extension .so files) gets picked up and
# re-signed by scripts/release/archive.sh's generic "sign every Mach-O under
# the app bundle" pass — nothing else to do here for signing.

# Verify the arch we actually copied, not just what BUILD_INFO.json claims —
# a stale or hand-edited BUILD_INFO.json must not silently pass this check.
ACTUAL_ARCH="$(lipo -archs "${DEST_FILE}" 2>/dev/null || true)"
if [ "${ACTUAL_ARCH}" != "arm64" ]; then
  echo "error: bundled eos1v_tool binary is actually '${ACTUAL_ARCH}', not arm64 as required."
  exit 1
fi

echo "Bundled eos1v-tool (submodule ${BUNDLED_COMMIT}, arch ${ACTUAL_ARCH}) from ${SRC}"
