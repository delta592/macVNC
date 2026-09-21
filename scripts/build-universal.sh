#!/bin/bash
# Build a universal (arm64 + x86_64) macVNC.app using MacPorts fat libraries.
# Usage: ./scripts/build-universal.sh [build-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-universal}"
PREFIX="${CMAKE_PREFIX_PATH:-/opt/local}"

echo "Configuring universal build (prefix=$PREFIX, dir=$BUILD)"
cmake -S "$ROOT" -B "$BUILD" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DMACVNC_UNIVERSAL=ON \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

cmake --build "$BUILD"
BIN="$BUILD/macVNC.app/Contents/MacOS/macVNC"
echo "Result:"
lipo -info "$BIN"
file "$BIN"
