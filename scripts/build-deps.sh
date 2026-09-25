#!/usr/bin/env bash
# Build OpenSSL and LibVNCServer from source for one or more macOS architectures,
# then (when multiple arches) lipo static libraries into a universal prefix.
#
# No Homebrew/MacPorts packages are required — only Xcode CLT, CMake, curl, and
# a C toolchain (Apple Clang).
#
# Usage:
#   ./scripts/build-deps.sh                 # both arm64 and x86_64 → universal
#   ./scripts/build-deps.sh --arch=arm64    # host-only / single arch
#   ./scripts/build-deps.sh --force         # rebuild even if stamp matches
#
# Layout under deps/:
#   src/              downloaded tarballs + extracted trees
#   build/<arch>/     per-arch build dirs
#   prefix/<arch>/    per-arch installs
#   prefix/universal/ lipo'd libs + headers (when ≥2 arches)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_ROOT="${MACVNC_DEPS_ROOT:-$ROOT/deps}"
SRC_DIR="$DEPS_ROOT/src"
BUILD_ROOT="$DEPS_ROOT/build"
PREFIX_ROOT="$DEPS_ROOT/prefix"

OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.8}"
OPENSSL_SHA256="${OPENSSL_SHA256:-a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2}"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

LIBVNCSERVER_VERSION="${LIBVNCSERVER_VERSION:-0.9.15}"
LIBVNCSERVER_SHA256="${LIBVNCSERVER_SHA256:-62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7}"
LIBVNCSERVER_URL="https://github.com/LibVNC/libvncserver/archive/refs/tags/LibVNCServer-${LIBVNCSERVER_VERSION}.tar.gz"

DEPLOYMENT_TARGET="${MACVNC_OSX_DEPLOYMENT_TARGET:-15.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
FORCE=0
ARCHS=()

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage 0 ;;
    --force) FORCE=1 ;;
    --arch=*) ARCHS+=("${arg#--arch=}") ;;
    *)
      echo "unknown argument: $arg" >&2
      usage 1
      ;;
  esac
done

if [[ ${#ARCHS[@]} -eq 0 ]]; then
  ARCHS=(arm64 x86_64)
fi

for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *)
      echo "unsupported arch: $arch (expected arm64 or x86_64)" >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

need_cmd cmake
need_cmd curl
need_cmd tar
need_cmd make
need_cmd lipo
need_cmd clang

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

download() {
  local url="$1" dest="$2" expect_sha="$3"
  if [[ -f "$dest" ]]; then
    local got
    got="$(sha256_file "$dest")"
    if [[ "$got" == "$expect_sha" ]]; then
      return 0
    fi
    echo "checksum mismatch for $dest (got $got, want $expect_sha); re-downloading"
    rm -f "$dest"
  fi
  echo "Downloading $url"
  curl -fL --retry 3 --retry-delay 2 -o "$dest.partial" "$url"
  local got
  got="$(sha256_file "$dest.partial")"
  if [[ "$got" != "$expect_sha" ]]; then
    echo "checksum failed for $dest: got $got, expected $expect_sha" >&2
    rm -f "$dest.partial"
    exit 1
  fi
  mv "$dest.partial" "$dest"
}

extract_once() {
  local tarball="$1" dest_dir="$2" stamp="$3"
  if [[ -f "$stamp" && -d "$dest_dir" && $FORCE -eq 0 ]]; then
    return 0
  fi
  rm -rf "$dest_dir"
  mkdir -p "$(dirname "$dest_dir")"
  local tmp
  tmp="$(mktemp -d "$SRC_DIR/extract.XXXXXX")"
  tar -xzf "$tarball" -C "$tmp"
  # Normalise nested top-level directory name.
  local top
  top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  mv "$top" "$dest_dir"
  rm -rf "$tmp"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$stamp"
}

openssl_target() {
  case "$1" in
    arm64) echo darwin64-arm64-cc ;;
    x86_64) echo darwin64-x86_64-cc ;;
  esac
}

build_openssl() {
  local arch="$1"
  local prefix="$PREFIX_ROOT/$arch"
  local build="$BUILD_ROOT/openssl-$arch"
  local stamp="$prefix/.stamp-openssl-${OPENSSL_VERSION}"

  if [[ -f "$stamp" && -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" && $FORCE -eq 0 ]]; then
    echo "OpenSSL $OPENSSL_VERSION ($arch) already built → $prefix"
    return 0
  fi

  echo "=== Building OpenSSL $OPENSSL_VERSION for $arch ==="
  rm -rf "$build"
  mkdir -p "$build"
  # Configure in a fresh tree — OpenSSL writes into the source dir.
  local src_copy="$build/src"
  rm -rf "$src_copy"
  cp -a "$SRC_DIR/openssl-${OPENSSL_VERSION}" "$src_copy"
  pushd "$src_copy" >/dev/null

  local target
  target="$(openssl_target "$arch")"
  env -u PKG_CONFIG_PATH -u LDFLAGS -u CPPFLAGS -u CFLAGS \
    ./Configure "$target" \
    --prefix="$prefix" \
    --openssldir="$prefix/ssl" \
    no-shared \
    no-tests \
    no-apps \
    no-docs \
    -mmacosx-version-min="$DEPLOYMENT_TARGET"

  make -j"$JOBS"
  # Avoid `make install_docs` / man pages.
  make install_sw

  popd >/dev/null
  echo "$OPENSSL_VERSION" >"$stamp"
  echo "OpenSSL installed → $prefix"
}

# Versioned patches under patches/libvncserver-<ver>/ applied after extract.
# Bump PATCH_REV when patches change so stamps force a rebuild.
LIBVNCSERVER_PATCH_REV="${LIBVNCSERVER_PATCH_REV:-1}"

apply_libvncserver_patches() {
  local src="$1"
  local patch_dir="$ROOT/patches/libvncserver-${LIBVNCSERVER_VERSION}"
  local marker="$src/.macvnc-patches-applied-${LIBVNCSERVER_PATCH_REV}"
  local p
  local tarball="$SRC_DIR/libvncserver-${LIBVNCSERVER_VERSION}.tar.gz"
  local extract_stamp="$SRC_DIR/.stamp-libvncserver-${LIBVNCSERVER_VERSION}"

  if [[ -f "$marker" && $FORCE -eq 0 ]]; then
    return 0
  fi

  need_cmd patch

  # Always start from a pristine extract when (re)applying a patch revision.
  echo "=== Refreshing LibVNCServer ${LIBVNCSERVER_VERSION} sources for patch rev ${LIBVNCSERVER_PATCH_REV} ==="
  FORCE=1 extract_once "$tarball" "$src" "$extract_stamp"

  if [[ ! -d "$patch_dir" ]]; then
    echo "warning: no LibVNCServer patches at $patch_dir" >&2
    date -u +%Y-%m-%dT%H:%M:%SZ >"$marker"
    return 0
  fi

  echo "=== Applying LibVNCServer patches (rev $LIBVNCSERVER_PATCH_REV) ==="
  shopt -s nullglob
  for p in "$patch_dir"/*.patch; do
    echo "  patch: $(basename "$p")"
    patch -p1 -d "$src" -i "$p"
  done
  shopt -u nullglob
  date -u +%Y-%m-%dT%H:%M:%SZ >"$marker"
}

build_libvncserver() {
  local arch="$1"
  local prefix="$PREFIX_ROOT/$arch"
  local build="$BUILD_ROOT/libvncserver-$arch"
  local stamp="$prefix/.stamp-libvncserver-${LIBVNCSERVER_VERSION}-p${LIBVNCSERVER_PATCH_REV}"

  if [[ -f "$stamp" && -f "$prefix/lib/libvncserver.a" && $FORCE -eq 0 ]]; then
    echo "LibVNCServer $LIBVNCSERVER_VERSION-p${LIBVNCSERVER_PATCH_REV} ($arch) already built → $prefix"
    return 0
  fi

  if [[ ! -f "$prefix/lib/libssl.a" ]]; then
    echo "OpenSSL for $arch must be built first" >&2
    exit 1
  fi

  apply_libvncserver_patches "$SRC_DIR/libvncserver-${LIBVNCSERVER_VERSION}"

  echo "=== Building LibVNCServer $LIBVNCSERVER_VERSION-p${LIBVNCSERVER_PATCH_REV} for $arch ==="
  rm -rf "$build"
  mkdir -p "$build"

  # Isolate from Homebrew/MacPorts so optional deps (LZO, JPEG, …) are not
  # pulled in from package managers. zlib/sasl come from the macOS SDK.
  env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR \
    -u CMAKE_PREFIX_PATH -u LDFLAGS -u CPPFLAGS -u CFLAGS \
    cmake -S "$SRC_DIR/libvncserver-${LIBVNCSERVER_VERSION}" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/opt/local;/usr/local" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_OPENSSL=ON \
    -DWITH_GNUTLS=OFF \
    -DWITH_GCRYPT=OFF \
    -DWITH_WEBSOCKETS=ON \
    -DWITH_ZLIB=ON \
    -DWITH_LZO=OFF \
    -DWITH_JPEG=OFF \
    -DWITH_PNG=OFF \
    -DWITH_SDL=OFF \
    -DWITH_GTK=OFF \
    -DWITH_QT=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SYSTEMD=OFF \
    -DWITH_LIBSSHTUNNEL=OFF \
    -DWITH_EXAMPLES=OFF \
    -DWITH_TESTS=OFF \
    -DOPENSSL_ROOT_DIR="$prefix" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  cmake --build "$build" --parallel "$JOBS"
  cmake --install "$build"

  # Drop any accidental package-manager link lines from the exported targets.
  local targets="$prefix/lib/cmake/LibVNCServer/LibVNCServerTargets.cmake"
  if [[ -f "$targets" ]]; then
    if grep -qE '/opt/homebrew|/opt/local|/usr/local' "$targets"; then
      echo "warning: scrubbing package-manager paths from $targets" >&2
      sed -i '' \
        -e 's|;/opt/homebrew[^;"]*||g' \
        -e 's|;/opt/local[^;"]*||g' \
        -e 's|;/usr/local[^;"]*||g' \
        -e 's|/opt/homebrew[^;"]*;||g' \
        -e 's|/opt/local[^;"]*;||g' \
        -e 's|/usr/local[^;"]*;||g' \
        "$targets"
    fi
  fi

  # Ensure a plain archive name exists (some installs use lib/libvncserver.a already).
  if [[ ! -f "$prefix/lib/libvncserver.a" ]]; then
    echo "expected $prefix/lib/libvncserver.a after install" >&2
    exit 1
  fi

  echo "${LIBVNCSERVER_VERSION}-p${LIBVNCSERVER_PATCH_REV}" >"$stamp"
  echo "LibVNCServer installed → $prefix"
}

lipo_universal() {
  if [[ ${#ARCHS[@]} -lt 2 ]]; then
    # Single-arch build: do NOT clobber an existing fat universal tree.
    # Studio→Intel workflows need deps/prefix/universal to stay arm64+x86_64.
    local only="${ARCHS[0]}"
    local uni="$PREFIX_ROOT/universal"
    local uni_lib="$uni/lib/libvncserver.a"

    if [[ -L "$uni" ]]; then
      # Previous single-arch convenience symlink — replace with a pointer to this arch.
      rm -f "$uni"
      mkdir -p "$PREFIX_ROOT"
      ln -sfn "$only" "$uni"
      echo "Single-arch deps ready → $PREFIX_ROOT/$only (linked as universal)"
      echo "warning: universal is a symlink to $only only; run ./scripts/build-deps.sh" >&2
      echo "         (no --arch) before building a fat .app for Intel + Apple Silicon." >&2
      return 0
    fi

    if [[ -f "$uni_lib" ]]; then
      local archs
      archs="$(lipo -archs "$uni_lib" 2>/dev/null || true)"
      if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then
        echo "Keeping existing fat universal deps ($archs); single-arch build updated $only only."
        return 0
      fi
    fi

    mkdir -p "$PREFIX_ROOT"
    ln -sfn "$only" "$uni"
    echo "Single-arch deps ready → $PREFIX_ROOT/$only (linked as universal)"
    echo "warning: universal is a symlink to $only only; run ./scripts/build-deps.sh" >&2
    echo "         (no --arch) before building a fat .app for Intel + Apple Silicon." >&2
    return 0
  fi

  local uni="$PREFIX_ROOT/universal"
  local primary="${ARCHS[0]}"
  echo "=== Creating universal prefix from: ${ARCHS[*]} ==="
  # Remove symlink or stale tree so we always write a real fat prefix.
  rm -rf "$uni"
  mkdir -p "$uni/lib" "$uni/include" "$uni/lib/cmake" "$uni/lib/pkgconfig"

  # Headers and CMake/pkg-config metadata are arch-independent for our static builds.
  cp -a "$PREFIX_ROOT/$primary/include/." "$uni/include/"
  if [[ -d "$PREFIX_ROOT/$primary/lib/cmake" ]]; then
    cp -a "$PREFIX_ROOT/$primary/lib/cmake/." "$uni/lib/cmake/"
  fi
  if [[ -d "$PREFIX_ROOT/$primary/lib/pkgconfig" ]]; then
    cp -a "$PREFIX_ROOT/$primary/lib/pkgconfig/." "$uni/lib/pkgconfig/"
    # Rewrite prefix= in .pc files to the universal tree.
    local pc
    for pc in "$uni/lib/pkgconfig"/*.pc; do
      [[ -f "$pc" ]] || continue
      sed -i '' "s|^prefix=.*|prefix=$uni|" "$pc"
    done
  fi

  # OpenSSL openssl.cnf / ssl dir is optional for linking; skip docs.

  local lib name inputs
  for name in libcrypto.a libssl.a libvncserver.a libvncclient.a; do
    inputs=()
    for arch in "${ARCHS[@]}"; do
      lib="$PREFIX_ROOT/$arch/lib/$name"
      if [[ -f "$lib" ]]; then
        inputs+=("$lib")
      fi
    done
    if [[ ${#inputs[@]} -eq 0 ]]; then
      continue
    fi
    if [[ ${#inputs[@]} -ne ${#ARCHS[@]} ]]; then
      echo "missing $name for some architectures; skipping lipo" >&2
      continue
    fi
    lipo -create "${inputs[@]}" -output "$uni/lib/$name"
    echo "lipo → $uni/lib/$name ($(lipo -archs "$uni/lib/$name"))"
  done

  # Rewrite OpenSSL/LibVNC CMake package prefix hints where present.
  if [[ -d "$uni/lib/cmake" ]]; then
    find "$uni/lib/cmake" -type f \( -name '*.cmake' -o -name '*.pc' \) -print0 |
      while IFS= read -r -d '' f; do
        # Replace per-arch absolute prefixes with the universal one.
        for arch in "${ARCHS[@]}"; do
          sed -i '' "s|$PREFIX_ROOT/$arch|$uni|g" "$f"
        done
      done
  fi

  printf '%s\n' "${ARCHS[@]}" >"$uni/.architectures"
  echo "Universal deps ready → $uni"
}

verify_tls_headers() {
  local prefix="$1"
  local cfg
  cfg="$(find "$prefix/include" -name rfbconfig.h 2>/dev/null | head -1)"
  if [[ -z "$cfg" ]]; then
    echo "rfbconfig.h not found under $prefix/include" >&2
    exit 1
  fi
  if ! grep -q 'LIBVNCSERVER_HAVE_LIBSSL[[:space:]]*1' "$cfg"; then
    echo "LibVNCServer was not built with OpenSSL (check $cfg)" >&2
    grep 'LIBVNCSERVER_HAVE_LIBSSL\|LIBVNCSERVER_WITH_WEBSOCKETS' "$cfg" || true
    exit 1
  fi
  if ! grep -q 'LIBVNCSERVER_WITH_WEBSOCKETS[[:space:]]*1' "$cfg"; then
    echo "LibVNCServer was not built with WebSockets (required for TLS I/O path)" >&2
    exit 1
  fi
  echo "Verified TLS+WebSockets in $cfg"
}

mkdir -p "$SRC_DIR" "$BUILD_ROOT" "$PREFIX_ROOT"

download "$OPENSSL_URL" "$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_SHA256"
download "$LIBVNCSERVER_URL" "$SRC_DIR/libvncserver-${LIBVNCSERVER_VERSION}.tar.gz" "$LIBVNCSERVER_SHA256"

extract_once \
  "$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz" \
  "$SRC_DIR/openssl-${OPENSSL_VERSION}" \
  "$SRC_DIR/.stamp-openssl-${OPENSSL_VERSION}"

extract_once \
  "$SRC_DIR/libvncserver-${LIBVNCSERVER_VERSION}.tar.gz" \
  "$SRC_DIR/libvncserver-${LIBVNCSERVER_VERSION}" \
  "$SRC_DIR/.stamp-libvncserver-${LIBVNCSERVER_VERSION}"

for arch in "${ARCHS[@]}"; do
  build_openssl "$arch"
  build_libvncserver "$arch"
  verify_tls_headers "$PREFIX_ROOT/$arch"
done

lipo_universal

echo
echo "Done. Point CMake at:"
if [[ ${#ARCHS[@]} -ge 2 ]]; then
  echo "  -DMACVNC_DEPS_PREFIX=$PREFIX_ROOT/universal"
else
  echo "  -DMACVNC_DEPS_PREFIX=$PREFIX_ROOT/${ARCHS[0]}"
fi
echo "(or rely on auto-detection of deps/prefix/universal)."
