#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) macVNC.app using deps built from source.
# Usage: ./scripts/build-universal.sh [build-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-universal}"
DEPS_PREFIX="${MACVNC_DEPS_PREFIX:-$ROOT/deps/prefix/universal}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

if [[ ! -f "$DEPS_PREFIX/lib/libvncserver.a" || ! -f "$DEPS_PREFIX/lib/libssl.a" ]]; then
  echo "Building from-source dependencies (arm64 + x86_64)…"
  "$ROOT/scripts/build-deps.sh"
fi

if [[ ! -f "$DEPS_PREFIX/lib/libvncserver.a" ]]; then
  echo "missing $DEPS_PREFIX/lib/libvncserver.a — run scripts/build-deps.sh first" >&2
  exit 1
fi

echo "Configuring universal build (deps=$DEPS_PREFIX, dir=$BUILD)"
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
