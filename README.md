[![CI](https://github.com/delta592/macVNC/actions/workflows/ci.yml/badge.svg)](https://github.com/delta592/macVNC/actions/workflows/ci.yml)

# About

macVNC is a simple command-line VNC server for macOS.

It is [based on the macOS server example from LibVNCServer](https://github.com/LibVNC/libvncserver/commits/6e5f96e3ea53bf85cec7d985b120daf1c91ce0d9/examples/mac.c?browsing_rename_history=true&new_path=examples/server/mac.c&original_branch=master)
which in turn is based on OSXvnc by Dan McGuirk which again is based on the original VNC
GPL dump by AT&T Cambridge.

## Features

* Fully multi-threaded.
* Bounded latest-frame capture pipeline with dirty-region tracking (does not
  block ScreenCaptureKit on client encode/TLS locks).
* Separate cursor shape/position updates (pointer motion does not dirty the
  whole framebuffer for capable viewers).
* Mouse and keyboard input.
* Multi-monitor support.
* Capture controls: `-maxfps` (default **30**, tuned for Intel Macs), `-scale`.
* **VeNCrypt / TLS encryption** (default) — no SSH tunnel required. Works with
  encryption-capable viewers such as TigerVNC Viewer.
* **Universal binary** (arm64 + x86_64) via per-arch from-source dependencies.

## Supported environments

| | Requirement |
|--|--|
| macOS | 15.0+ (ScreenCaptureKit) |
| Toolchain | Xcode Command Line Tools + CMake |
| Architectures | arm64, x86_64, or universal (both) |
| LibVNCServer TLS | OpenSSL (built from source with WebSockets) |

Minimum deployment target is **macOS 15.0**.

# Building

Dependencies (**OpenSSL** and **LibVNCServer**) are built from source — no
Homebrew or MacPorts packages are required for linking. You still need:

* Xcode Command Line Tools (`xcode-select --install`)
* [CMake](https://cmake.org/download/) ≥ 3.18 on `PATH`
* [ccache](https://ccache.dev/) on `PATH` (e.g. `brew install ccache`)
* `curl`, `tar`, `make`, Apple Clang (all ship with the CLT)

## 1. Build dependencies

```bash
# Both architectures → deps/prefix/universal (recommended)
./scripts/build-deps.sh

# Or a single architecture (faster for local/CI native builds)
./scripts/build-deps.sh --arch="$(uname -m)"
```

This downloads pinned OpenSSL and LibVNCServer releases, builds each requested
CPU architecture separately (static libraries), then `lipo`s them into
`deps/prefix/universal` when more than one arch is requested.

| Path | Contents |
|------|----------|
| `deps/src/` | Downloaded tarballs + extracted trees |
| `deps/prefix/<arch>/` | Per-arch install prefix |
| `deps/prefix/universal/` | Fat static libs + headers |

Rebuild with `./scripts/build-deps.sh --force`. Full wipe (build trees, deps,
and packaged artifacts): `make scrub`. `make distclean` keeps `dist/`.

## 2. Configure & build macVNC

CMake auto-detects `deps/prefix/universal` (or a single-arch prefix).

### Universal app (arm64 + x86_64) — use this on Mac Studio for the Intel iMac

```bash
./scripts/build-deps.sh          # both arches (do not pass --arch=…)
make universal                   # → build-universal/macVNC.app
lipo -info build-universal/macVNC.app/Contents/MacOS/macVNC
# expect: Architectures in the fat file: ... x86_64 arm64
```

Copy **`build-universal/macVNC.app`** (or `make dist`’s `.dmg`) to the iMac.

`make` / `make build` uses `build/` and follows `UNIVERSAL` (default ON). For a
dedicated fat artifact that will not collide with a native experiment tree,
prefer **`make universal`** → always `build-universal/`.

### Make / Ninja / ccache

```bash
make deps                         # from-source OpenSSL + LibVNCServer (optional;
                                  #   also runs automatically before configure)
make                              # ensure deps + configure + build → build/
make universal                    # fat .app → build-universal/
make GENERATOR=Ninja              # faster incremental builds
make UNIVERSAL=OFF                # native-only into build/
make DEPS_ARCH=arm64 deps         # single-arch deps only
make test                         # CTest unit tests
make COVERAGE=ON coverage         # LLVM coverage + lcov/HTML under build/
make format-check                 # clang-format on maintained sources
make tidy                         # clang-tidy via compile_commands.json
make dist                         # universal .pkg inside .dmg (Intel + Apple Silicon)
make scrub                        # wipe build/, build-universal/, deps/, dist/
```

`ccache` is **required** (configure fails if it is missing). Install with
`brew install ccache` or see https://ccache.dev/download.html. Bypass only if
needed with `-DMACVNC_USE_CCACHE=OFF`.

## Distributing (universal pkg inside dmg)

`make dist` builds a **universal** (`arm64` + `x86_64`) `.app` from the
from-source deps prefix, finalizes the bundle, ad-hoc signs it, wraps it in a
product `.pkg` that installs to `/Applications/macVNC.app`, and puts that
package in a compressed `.dmg`.

That single installer runs on:

* **macOS 15.x Intel** (x86_64 slice)
* **macOS 15.x+ Apple Silicon** (arm64 slice)

```bash
# Snapshot (sha + UTC timestamp); keeps prior artifacts in dist/
make dist
# → dist/macVNC-0.1.0-universal-<sha>-<YYYYMMDDTHHMMSSZ>.pkg
# → dist/macVNC-0.1.0-universal-<sha>-<YYYYMMDDTHHMMSSZ>.dmg
# → dist/macVNC-universal-latest.{pkg,dmg}  (symlinks to this build)

# Production / release naming (tag):
make dist DIST_TAG=v2.2.0
# → dist/macVNC-v2.2.0-universal.{pkg,dmg}
# Or check out a tag (clean tree) and run make dist — same naming.
```

Copy the `.dmg` to the other Mac, open it, run the `.pkg` (admin password),
then grant **Screen Recording**, **Accessibility**, and **Local Network** to
macVNC under System Settings → Privacy & Security.

The disk image also includes **Uninstall macVNC.command**, which removes
`/Applications/macVNC.app`, forgets the installer receipt, and unloads the
optional LaunchAgent. It leaves `~/.macvnc` (certs) alone.

Prior builds under `dist/` are kept. Snapshot names include git sha and a UTC
timestamp so they never collide. Release names are stable; rebuild with
`DIST_FORCE=1` only if you intentionally replace a release artifact.

| Target | Output |
|--------|--------|
| `make dist` | universal `.pkg` + `.dmg` under `DIST_DIR` (default `dist/`) |
| `make pkg` | universal product `.pkg` only |
| `make universal` | universal `.app` in `DIST_BUILD_DIR` (default `build-universal/`) |
| `make scrub` | wipe `build/`, `build-universal/`, `deps/`, and `dist/` |

`make dist` **fails** if any Mach-O in the bundle is missing `arm64` or
`x86_64`. The installer XML also sets `hostArchitectures` to `x86_64,arm64`
and requires macOS 15.0.

The package is **ad-hoc signed**, not notarized. On first open the other Mac
may quarantine the disk image; right-click → Open, or:

```bash
xattr -d com.apple.quarantine ~/Downloads/macVNC-*.dmg
```

Other useful variables: `DIST_DIR`, `DIST_BUILD_DIR`, `DIST_TAG`,
`DIST_RELEASE`, `DIST_FORCE`, `DIST_VERSION`, `DIST_INSTALL_LOCATION`,
`DIST_IDENTITY` (pass a Developer ID if you have one).

# Running

```bash
# On the machine you built for (or any Mac, if the .app is universal):
./build-universal/macVNC.app/Contents/MacOS/macVNC -rfbport 5901 -passwd 'secret'
# Native-only Studio build (arm64): ./build/macVNC.app/Contents/MacOS/macVNC …
```

If Apple's Remote Desktop already owns port 5900, pick another port as above.

**Mac Studio → 2019 Intel iMac:** ship the fat app from `make universal` /
`build-universal/macVNC.app`. On the iMac, start with defaults (`-maxfps 30`)
and prefer Hextile in the viewer while measuring. If encode CPU is still high,
try `-scale 0.5` or lower `-maxfps`. After pulling changes under
`patches/libvncserver-*`, re-run `./scripts/build-deps.sh` (both arches) so the
patched LibVNCServer is installed.

| Flag | Meaning |
|------|---------|
| `-maxfps <1-60>` | Capture rate cap (default: `30`) |
| `-scale <0.25-1.0>` | Capture + framebuffer scale; preserves aspect (default: `1.0`) |
| `-tile-size 32\|64` | Dirty-diff tile size (default: `64`) |
| `-metrics` | Log aggregated capture/publish counters every 10s (`MACVNC_METRICS=1` also works) |

## Encryption (default)

By default the server uses **VeNCrypt with an X.509 certificate**. On first run it
auto-generates a self-signed cert/key under:

```text
~/.macvnc/cert.pem
~/.macvnc/key.pem
```

(The private key is created mode `0600` and the certificate mode `0644`,
both via `open`+`fchmod` so creation is never world-writable. Paths avoid
spaces so TigerVNC’s `-X509CA` works.)

| Flag | Meaning |
|------|---------|
| `-security vencrypt` | VeNCrypt + X.509 (default) |
| `-security anontls` | VeNCrypt AnonTLS (encrypted; server identity not authenticated) |
| `-security plain` | Legacy unencrypted VNC auth (compatibility / testing only) |
| `-regen-cert` | Force-regenerate the self-signed certificate |

### TigerVNC Viewer

```bash
/Applications/TigerVNC.app/Contents/MacOS/vncviewer \
  -X509CA "$HOME/.macvnc/cert.pem" host::5901
```

Apple Screen Sharing does **not** speak VeNCrypt.

## Permissions

Grant these under System Settings → Privacy & Security:

* **Accessibility** — keyboard/mouse injection
* **Screen Recording** — ScreenCaptureKit capture
* **Local Network** — required for viewers (and often Terminal/iTerm) to
  reach LAN hosts on macOS 15+; missing permission often surfaces as
  **No route to host**

If launched from Terminal/iTerm, some TCC entries may show as **Terminal** /
**iTerm**, not macVNC.

# Development

## Tests

CTest covers cert path/generation, security mode names, frame-pipeline tile
diff/coalesce, publisher start/stop with full and partial damage, metrics
counters, and cursor coordinate mapping plus shape/position poll lifecycle:

```bash
make UNIVERSAL=OFF test
# or: ctest --test-dir build --output-on-failure
```

Coverage (`make COVERAGE=ON coverage`) merges profiles from all CTest binaries
(`test_cert_manager`, `test_security_mode`, `test_frame_pipeline`,
`test_macvnc_metrics`, `test_cursor_map`). ScreenCaptureKit stream I/O and the
live VeNCrypt handshake path remain integration/manual (host + TigerVNC).

Optional XCTest bundle (same cases) when generating an Xcode project:

```bash
cmake -S . -B build-xcode -G Xcode -DMACVNC_BUILD_XCTEST=ON -DMACVNC_UNIVERSAL=OFF
cmake --build build-xcode
```

## Coverage

```bash
make COVERAGE=ON coverage
# → build/coverage.lcov and build/coverage-html/
```

CI uploads `coverage.lcov` as an artifact. Set a `CODECOV_TOKEN` repo secret to
enable Codecov uploads.

## LaunchAgent (launchd)

Background the server as a per-user agent:

```bash
make UNIVERSAL=OFF build
MACVNC_PASSWD='secret' make launchd-load    # port 5901, VeNCrypt by default
make launchd-status
make launchd-unload
```

Template: `contrib/launchd/net.macvnc.server.plist` (rendered by
`scripts/launchd.sh`). Override with `MACVNC_PROGRAM`, `MACVNC_RFBPORT`,
`MACVNC_SECURITY`, `MACVNC_PASSWD`.

Grant Accessibility / Screen Recording / Local Network to the binary (or to
`launchd`’s host context) before expecting input and capture to work.

# License

As its predecessors, macVNC is licensed under the GPL version 2. See [COPYING](COPYING) for more information.
