#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) macVNC.app using deps built from source.
# Usage: ./scripts/build-universal.sh [build-dir]
#
# On Apple Silicon (e.g. Mac Studio), this is the artifact to copy to an Intel
# Mac. Do not use a native-only build/ tree (MACVNC_UNIVERSAL=OFF) for that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-universal}"
DEPS_PREFIX="${MACVNC_DEPS_PREFIX:-$ROOT/deps/prefix/universal}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

require_fat_lib() {
  local lib="$1"
  local archs
  if [[ ! -f "$lib" ]]; then
    return 1
  fi
  if [[ -L "$DEPS_PREFIX" ]]; then
    echo "error: $DEPS_PREFIX is a symlink to a single-arch prefix." >&2
    echo "       Run: ./scripts/build-deps.sh   # both arches, no --arch" >&2
    return 1
  fi
  archs="$(lipo -archs "$lib" 2>/dev/null || true)"
  if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
    echo "error: $lib is not universal (archs: ${archs:-unknown})" >&2
    echo "       Run: ./scripts/build-deps.sh   # both arches, no --arch" >&2
    return 1
  fi
  return 0
}

if ! require_fat_lib "$DEPS_PREFIX/lib/libvncserver.a" || ! require_fat_lib "$DEPS_PREFIX/lib/libssl.a"; then
  echo "Building from-source dependencies (arm64 + x86_64)…"
  "$ROOT/scripts/build-deps.sh"
fi

if ! require_fat_lib "$DEPS_PREFIX/lib/libvncserver.a"; then
  echo "missing fat $DEPS_PREFIX/lib/libvncserver.a after build-deps" >&2
  exit 1
fi
if ! require_fat_lib "$DEPS_PREFIX/lib/libssl.a"; then
  echo "missing fat $DEPS_PREFIX/lib/libssl.a after build-deps" >&2
  exit 1
fi

echo "Configuring universal build (deps=$DEPS_PREFIX, dir=$BUILD)"
echo "  libvncserver archs: $(lipo -archs "$DEPS_PREFIX/lib/libvncserver.a")"
# Clear package-manager link flags that may be present in the user environment.
env -u PKG_CONFIG_PATH -u LDFLAGS -u CPPFLAGS \
  cmake -S "$ROOT" -B "$BUILD" \
  -DMACVNC_DEPS_PREFIX="$DEPS_PREFIX" \
  -DMACVNC_UNIVERSAL=ON \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

BIN="$BUILD/macVNC.app/Contents/MacOS/macVNC"
echo "Result:"
lipo -info "$BIN"
file "$BIN"

archs="$(lipo -archs "$BIN" 2>/dev/null || true)"
if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
  echo "error: built app is not universal (archs: ${archs:-unknown})" >&2
  exit 1
fi

# Print a relative path when the build dir is under the repo.
REL_APP="$BUILD/macVNC.app"
case "$BUILD" in
  "$ROOT"/*) REL_APP="${BUILD#"$ROOT"/}/macVNC.app" ;;
esac
echo "OK: universal app ready → $REL_APP"
echo "    Copy that .app (or make dist) to the Intel iMac."
if [[ "$BUILD" == "$ROOT/build" || "$BUILD" == "build" || "$BUILD" == "$ROOT/build/"* ]]; then
  echo "    note: this overwrote build/; prefer: make universal  # → build-universal/" >&2
fi