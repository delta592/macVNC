[![CI](https://github.com/LibVNC/macVNC/actions/workflows/ci.yml/badge.svg)](https://github.com/LibVNC/macVNC/actions/workflows/ci.yml)

# About

macVNC is a simple command-line VNC server for macOS.

It is [based on the macOS server example from LibVNCServer](https://github.com/LibVNC/libvncserver/commits/6e5f96e3ea53bf85cec7d985b120daf1c91ce0d9/examples/mac.c?browsing_rename_history=true&new_path=examples/server/mac.c&original_branch=master)
which in turn is based on OSXvnc by Dan McGuirk which again is based on the original VNC
GPL dump by AT&T Cambridge.

## Features

* Fully multi-threaded.
* Double-buffering for framebuffer updates.
* Mouse and keyboard input.
* Multi-monitor support.
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

Rebuild with `./scripts/build-deps.sh --force`. Remove everything with
`make distclean`.

## 2. Configure & build macVNC

CMake auto-detects `deps/prefix/universal` (or a single-arch prefix).

### Universal app (arm64 + x86_64)

```bash
./scripts/build-universal.sh
# or: make universal
lipo -info build-universal/macVNC.app/Contents/MacOS/macVNC
# expect: Architectures in the fat file: ... x86_64 arm64
```

### Native-only

```bash
./scripts/build-deps.sh --arch="$(uname -m)"
cmake -S . -B build -DMACVNC_UNIVERSAL=OFF
cmake --build build
```

### Make / Ninja / ccache

```bash
make deps                         # from-source OpenSSL + LibVNCServer (optional;
                                  #   also runs automatically before configure)
make                              # ensure deps + configure + build
make GENERATOR=Ninja              # faster incremental builds
make UNIVERSAL=OFF                # native arch (deps + app)
make DEPS_ARCH=arm64 deps         # single-arch deps only
make test                         # CTest unit tests
make COVERAGE=ON coverage         # LLVM coverage + lcov/HTML under build/
make format-check                 # clang-format on maintained sources
make tidy                         # clang-tidy via compile_commands.json
```

`ccache` is **required** (configure fails if it is missing). Install with
`brew install ccache` or see https://ccache.dev/download.html. Bypass only if
needed with `-DMACVNC_USE_CCACHE=OFF`.

# Running

```bash
./build/macVNC.app/Contents/MacOS/macVNC -rfbport 5901 -passwd 'secret'
```

If Apple's Remote Desktop already owns port 5900, pick another port as above.

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

CTest covers cert path/generation and security mode names:

```bash
make UNIVERSAL=OFF test
# or: ctest --test-dir build --output-on-failure
```

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
