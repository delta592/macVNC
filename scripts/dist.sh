#!/usr/bin/env bash
# Package a finalized universal macVNC.app as a .pkg inside a .dmg.
# The installer is for macOS 15.x Intel and macOS 15.x+ Apple Silicon.
#
# Usage: ./scripts/dist.sh [build-dir]
#
# Env:
#   DIST_DIR                 output directory (default: <repo>/dist)
#   DIST_FORMAT              both | pkg | dmg   (default: both)
#   DIST_REQUIRE_UNIVERSAL   1 (default) fail unless every Mach-O is arm64+x86_64
#   DIST_REQUIRE_INTEL       legacy; 0 relaxes the universal requirement
#   DIST_SKIP_INSTALL        1 skip cmake --install (bundle already finalized)
#   DIST_IDENTITY            codesign identity (default: "-" ad-hoc)
#   DIST_INSTALL_LOCATION    default /Applications
#   DIST_VERSION             override package version (CFBundle / pkg version)
#   DIST_TAG                 release/tag name → production artifact naming
#   DIST_RELEASE             1 force release naming (uses DIST_TAG or exact git tag)
#   DIST_FORCE               1 allow overwriting an existing release artifact
#   DIST_MIN_OS              default 15.0
#   DIST_NAME                fully override the artifact stem (rare)
#
# Artifact names (never overwrite prior builds unless DIST_FORCE=1 on a release):
#   release:  macVNC-<tag>-<arch>.{pkg,dmg}
#   snapshot: macVNC-<version>-<arch>-<sha>-<UTC timestamp>.{pkg,dmg}
# Latest snapshot/release also refreshes macVNC-<arch>-latest.{pkg,dmg} symlinks.
set -euo pipefail

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
  exit 2
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-universal}"
APP="${BUILD}/macVNC.app"
BIN="${APP}/Contents/MacOS/macVNC"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
DIST_FORMAT="${DIST_FORMAT:-both}"
DIST_REQUIRE_UNIVERSAL="${DIST_REQUIRE_UNIVERSAL:-1}"
DIST_SKIP_INSTALL="${DIST_SKIP_INSTALL:-0}"
DIST_IDENTITY="${DIST_IDENTITY:--}"
DIST_INSTALL_LOCATION="${DIST_INSTALL_LOCATION:-/Applications}"
DIST_MIN_OS="${DIST_MIN_OS:-15.0}"
PKG_ID="net.macvnc.app"

# Legacy flag from the first packaging pass: 0 means "allow thin binaries".
if [[ "${DIST_REQUIRE_INTEL:-}" == "0" ]]; then
  DIST_REQUIRE_UNIVERSAL=0
fi

if [[ ! -d "${BUILD}" ]]; then
  echo "Missing build directory: ${BUILD}" >&2
  echo "Build a universal app first: make dist-app  (uses scripts/build-deps.sh)" >&2
  exit 1
fi

if [[ "${DIST_SKIP_INSTALL}" != "1" ]]; then
  echo "Finalizing bundle (cmake --install ${BUILD})"
  cmake --install "${BUILD}"
fi

if [[ ! -x "${BIN}" ]]; then
  echo "macVNC binary not found at ${BIN}" >&2
  exit 1
fi

version_from_cache() {
  local v=""
  if [[ -f "${BUILD}/CMakeCache.txt" ]]; then
    v="$(sed -n 's/^CMAKE_PROJECT_VERSION:STATIC=//p' "${BUILD}/CMakeCache.txt" | head -1)"
  fi
  printf '%s' "${v:-0.1.0}"
}

VERSION="${DIST_VERSION:-$(version_from_cache)}"

# Resolve build identity for artifact naming.
git_sha_short() {
  git -C "${ROOT}" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown'
}

git_exact_tag() {
  git -C "${ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true
}

sanitize_name() {
  # Keep filesystem-safe: letters, digits, dot, underscore, hyphen.
  printf '%s' "$1" | tr '/ ' '--' | tr -cd 'A-Za-z0-9._-'
}

SHA="$(git_sha_short)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EXACT_TAG="$(git_exact_tag)"
RELEASE_TAG="${DIST_TAG:-}"
IS_RELEASE=0

if [[ -n "${RELEASE_TAG}" ]]; then
  IS_RELEASE=1
elif [[ "${DIST_RELEASE:-0}" == "1" ]]; then
  if [[ -z "${EXACT_TAG}" ]]; then
    echo "error: DIST_RELEASE=1 but HEAD is not an exact git tag and DIST_TAG is unset." >&2
    exit 1
  fi
  RELEASE_TAG="${EXACT_TAG}"
  IS_RELEASE=1
elif [[ -n "${EXACT_TAG}" ]]; then
  RELEASE_TAG="${EXACT_TAG}"
  IS_RELEASE=1
fi

archs="$(lipo -archs "${BIN}" 2>/dev/null || true)"
arch_tag="native"
has_arm=0
has_x86=0
[[ " ${archs} " == *" arm64 "* ]] && has_arm=1
[[ " ${archs} " == *" x86_64 "* ]] && has_x86=1
if [[ "${has_arm}" -eq 1 && "${has_x86}" -eq 1 ]]; then
  arch_tag="universal"
elif [[ "${has_x86}" -eq 1 ]]; then
  arch_tag="x86_64"
elif [[ "${has_arm}" -eq 1 ]]; then
  arch_tag="arm64"
fi

if [[ -n "${DIST_NAME:-}" ]]; then
  STEM="$(sanitize_name "${DIST_NAME}")"
elif [[ "${IS_RELEASE}" -eq 1 ]]; then
  STEM="$(sanitize_name "macVNC-${RELEASE_TAG}-${arch_tag}")"
  # Prefer the tag as the installer-visible version when not overridden.
  if [[ -z "${DIST_VERSION:-}" ]]; then
    VERSION="$(sanitize_name "${RELEASE_TAG#v}")"
  fi
else
  STEM="$(sanitize_name "macVNC-${VERSION}-${arch_tag}-${SHA}-${TIMESTAMP}")"
fi

echo "App:     ${APP}"
echo "Version: ${VERSION}"
echo "Archs:   ${archs:-unknown} (${arch_tag})"
echo "Min OS:  ${DIST_MIN_OS}"
if [[ "${IS_RELEASE}" -eq 1 ]]; then
  echo "Release: ${RELEASE_TAG}"
else
  echo "Build:   ${SHA} @ ${TIMESTAMP}"
fi
echo "Stem:    ${STEM}"

is_universal=0
[[ "${arch_tag}" == "universal" ]] && is_universal=1

if [[ "${is_universal}" -eq 0 && "${DIST_REQUIRE_UNIVERSAL}" == "1" ]]; then
  cat >&2 <<EOF
error: ${BIN} is not universal (${archs:-unknown}).
The installer must contain arm64 + x86_64 slices so it can run on
macOS 15.x Intel and macOS 15.x+ Apple Silicon.

Rebuild fat from-source deps, then a universal app:

  ./scripts/build-deps.sh
  make dist

To package this non-universal build anyway (will not run on the other arch):

  DIST_REQUIRE_UNIVERSAL=0 ./scripts/dist.sh ${BUILD}
EOF
  exit 1
fi

if [[ "${is_universal}" -eq 0 ]]; then
  echo "warning: packaging a non-universal app; it will not run on both Intel and Apple Silicon." >&2
fi

# Stage under /tmp then copy into DIST_DIR (may be on an external volume).
WORKDIR="$(mktemp -d /tmp/macvnc-dist.XXXXXX)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

PAYLOAD="${WORKDIR}/payload"
COMPONENT_DIR="${WORKDIR}/component"
DMG_STAGE="${WORKDIR}/dmg"
mkdir -p "${PAYLOAD}" "${COMPONENT_DIR}" "${DMG_STAGE}" "${DIST_DIR}"

echo "Staging ${APP} -> ${PAYLOAD}/macVNC.app"
ditto "${APP}" "${PAYLOAD}/macVNC.app"
STAGED="${PAYLOAD}/macVNC.app"
STAGED_PLIST="${STAGED}/Contents/Info.plist"

# A bundle root may only contain Contents/ (and WrappedBundle). CMake used to
# drop README.md at the .app root, which breaks codesign.
if [[ -e "${STAGED}/README.md" ]]; then
  mkdir -p "${STAGED}/Contents/Resources"
  mv "${STAGED}/README.md" "${STAGED}/Contents/Resources/README.md"
fi
shopt -s nullglob
for stray in "${STAGED}"/*; do
  [[ "$(basename "${stray}")" == "Contents" ]] && continue
  echo "warning: removing non-bundle file from .app root: ${stray}" >&2
  rm -rf "${stray}"
done
shopt -u nullglob

ensure_bundle_id() {
  local current=""
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${STAGED_PLIST}" 2>/dev/null || true)"
    if [[ -z "${current}" ]]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${PKG_ID}" "${STAGED_PLIST}" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${PKG_ID}" "${STAGED_PLIST}"
    fi
    local ver
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${STAGED_PLIST}" 2>/dev/null || true)"
    if [[ -z "${ver}" ]]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${STAGED_PLIST}" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION}" "${STAGED_PLIST}"
    fi
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${DIST_MIN_OS}" "${STAGED_PLIST}" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string ${DIST_MIN_OS}" "${STAGED_PLIST}"
  fi
}

ensure_bundle_id

echo "Ad-hoc signing ${STAGED}"
xattr -cr "${STAGED}" 2>/dev/null || true
codesign --force --deep --sign "${DIST_IDENTITY}" --timestamp=none "${STAGED}"
codesign --verify --deep --strict "${STAGED}" 2>/dev/null || \
  codesign --verify --deep "${STAGED}"

macho_files() {
  find "${STAGED}" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) -print
}

# Fail if the bundle still points at Homebrew/MacPorts prefixes — those paths
# will not exist (or will be the wrong arch) on the other Mac.
check_relocatability() {
  local bad=0
  local f links
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    links="$(otool -L "${f}" 2>/dev/null || true)"
    if printf '%s\n' "${links}" | grep -Eq '/opt/homebrew|/opt/local|/usr/local'; then
      echo "error: ${f} still links to a package-manager prefix:" >&2
      printf '%s\n' "${links}" | grep -E '/opt/homebrew|/opt/local|/usr/local' >&2
      bad=1
    fi
  done < <(macho_files)
  if [[ "${bad}" -ne 0 ]]; then
    echo "Run cmake --install so BundleUtilities can copy dylibs into the .app." >&2
    exit 1
  fi
}

check_universal_slices() {
  local bad=0
  local f a
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    file "${f}" | grep -q 'Mach-O' || continue
    a="$(lipo -archs "${f}" 2>/dev/null || true)"
    if [[ " ${a} " != *" x86_64 "* || " ${a} " != *" arm64 "* ]]; then
      echo "error: not universal: ${f} (${a})" >&2
      bad=1
    fi
  done < <(macho_files)
  if [[ "${bad}" -ne 0 ]]; then
    echo "Every Mach-O in the bundle must include arm64 and x86_64." >&2
    echo "Build fat deps with ./scripts/build-deps.sh, then make dist." >&2
    exit 1
  fi
}

check_relocatability
if [[ "${DIST_REQUIRE_UNIVERSAL}" == "1" ]]; then
  check_universal_slices
fi

host_archs="arm64"
[[ " ${archs} " == *" x86_64 "* ]] && host_archs="x86_64,arm64"
[[ "${arch_tag}" == "x86_64" ]] && host_archs="x86_64"
if [[ "${is_universal}" -eq 1 ]]; then
  host_archs="x86_64,arm64"
fi

COMPONENT_PKG="${COMPONENT_DIR}/macVNC-component.pkg"
PRODUCT_PKG="${DIST_DIR}/${STEM}.pkg"
DMG_PATH="${DIST_DIR}/${STEM}.dmg"
LATEST_PKG="${DIST_DIR}/macVNC-${arch_tag}-latest.pkg"
LATEST_DMG="${DIST_DIR}/macVNC-${arch_tag}-latest.dmg"

if [[ -e "${PRODUCT_PKG}" || -e "${DMG_PATH}" ]]; then
  if [[ "${DIST_FORCE:-0}" == "1" ]]; then
    echo "warning: overwriting existing artifact(s) (DIST_FORCE=1)" >&2
    rm -f "${PRODUCT_PKG}" "${DMG_PATH}"
  else
    echo "error: artifact already exists (refusing to clobber prior build):" >&2
    [[ -e "${PRODUCT_PKG}" ]] && echo "  ${PRODUCT_PKG}" >&2
    [[ -e "${DMG_PATH}" ]] && echo "  ${DMG_PATH}" >&2
    echo "Snapshot builds include sha+timestamp and should not collide." >&2
    echo "For a release rebuild, set DIST_FORCE=1 or choose a new DIST_TAG." >&2
    exit 1
  fi
fi

# Record what this artifact is for later inspection.
BUILD_INFO="${DIST_DIR}/${STEM}.txt"
{
  echo "stem=${STEM}"
  echo "version=${VERSION}"
  echo "arch=${arch_tag}"
  echo "sha=${SHA}"
  echo "timestamp=${TIMESTAMP}"
  echo "release=${IS_RELEASE}"
  [[ -n "${RELEASE_TAG}" ]] && echo "tag=${RELEASE_TAG}"
  echo "build_dir=${BUILD}"
} > "${BUILD_INFO}"

COMPONENT_PLIST="${WORKDIR}/component.plist"
cat > "${COMPONENT_PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key>
    <true/>
    <key>BundleIsRelocatable</key>
    <false/>
    <key>BundleIsVersionChecked</key>
    <true/>
    <key>BundleOverwriteAction</key>
    <string>upgrade</string>
    <key>RootRelativeBundlePath</key>
    <string>macVNC.app</string>
  </dict>
</array>
</plist>
EOF

echo "Building component package"
pkgbuild \
  --root "${PAYLOAD}" \
  --component-plist "${COMPONENT_PLIST}" \
  --identifier "${PKG_ID}" \
  --version "${VERSION}" \
  --install-location "${DIST_INSTALL_LOCATION}" \
  --min-os-version "${DIST_MIN_OS}" \
  --ownership recommended \
  "${COMPONENT_PKG}"

DISTXML="${WORKDIR}/Distribution.xml"
cat > "${DISTXML}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>macVNC ${VERSION}</title>
    <organization>net.macvnc</organization>
    <options customize="never" require-scripts="false" hostArchitectures="${host_archs}"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="${DIST_MIN_OS}"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="${PKG_ID}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${PKG_ID}" visible="false">
        <pkg-ref id="${PKG_ID}"/>
    </choice>
    <pkg-ref id="${PKG_ID}" version="${VERSION}" onConclusion="none">macVNC-component.pkg</pkg-ref>
</installer-gui-script>
EOF

echo "Building product package ${PRODUCT_PKG}"
productbuild \
  --distribution "${DISTXML}" \
  --package-path "${COMPONENT_DIR}" \
  "${PRODUCT_PKG}"

if [[ "${DIST_FORMAT}" == "pkg" ]]; then
  echo "Wrote ${PRODUCT_PKG}"
  ln -sfn "$(basename "${PRODUCT_PKG}")" "${LATEST_PKG}"
  ls -lh "${PRODUCT_PKG}" "${LATEST_PKG}"
  exit 0
fi

echo "Building disk image ${DMG_PATH}"
cp "${PRODUCT_PKG}" "${DMG_STAGE}/"
cp "${ROOT}/README.md" "${DMG_STAGE}/"
cp "${ROOT}/COPYING" "${DMG_STAGE}/"
cp "${BUILD_INFO}" "${DMG_STAGE}/BUILD.txt"

UNINSTALL_SRC="${ROOT}/scripts/uninstall.sh"
UNINSTALL_DMG="${DMG_STAGE}/Uninstall macVNC.command"
cp "${UNINSTALL_SRC}" "${UNINSTALL_DMG}"
chmod 755 "${UNINSTALL_DMG}"

TMP_DMG="${WORKDIR}/${STEM}.dmg"
rm -f "${TMP_DMG}"
# Prefer the modern diskutil API; fall back to hdiutil on older macOS.
if diskutil image create from --help >/dev/null 2>&1; then
  diskutil image create from \
    --format UDZO \
    --volumeName "macVNC ${VERSION}" \
    "${DMG_STAGE}" \
    "${TMP_DMG}"
else
  hdiutil create \
    -volname "macVNC ${VERSION}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    "${TMP_DMG}"
fi
cp "${TMP_DMG}" "${DMG_PATH}"

if [[ "${DIST_FORMAT}" == "dmg" ]]; then
  rm -f "${PRODUCT_PKG}"
fi

# Point convenience "latest" symlinks at this build; leave prior artifacts intact.
ln -sfn "$(basename "${PRODUCT_PKG}")" "${LATEST_PKG}"
ln -sfn "$(basename "${DMG_PATH}")" "${LATEST_DMG}"

echo
echo "Wrote:"
[[ -f "${PRODUCT_PKG}" && "${DIST_FORMAT}" != "dmg" ]] && ls -lh "${PRODUCT_PKG}"
ls -lh "${DMG_PATH}"
echo "Latest links:"
ls -lh "${LATEST_PKG}" "${LATEST_DMG}" 2>/dev/null || true
echo
if [[ "${is_universal}" -eq 1 ]]; then
  echo "Install on macOS 15.x Intel or macOS 15.x+ Apple Silicon:"
else
  echo "This package is ${arch_tag}-only; it will not run on the other architecture."
  echo "For a dual-arch installer: make dist"
fi
echo "  copy the .dmg, open it, run the .pkg, then grant Screen Recording,"
echo "  Accessibility, and Local Network to macVNC."
echo "  To remove later: open the .dmg and double-click Uninstall macVNC.command."
