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
* **Universal binary** (arm64 + x86_64) when built with fat/universal dependencies.

## Supported environments

| | Older Intel host | Modern Apple Silicon host |
|--|--|--|
| macOS | 15.x | 26+/27+ (and generally 15+) |
| Package manager | **MacPorts** (`/opt/local`) | **Homebrew** (`/opt/homebrew`) |
| CPU | x86_64 | arm64 |
| LibVNCServer TLS | GnuTLS (MacPorts default) | OpenSSL (Homebrew bottle) |

Minimum deployment target is **macOS 15.0**. ScreenCaptureKit is required.

# Building

## Dependencies

You need **LibVNCServer with TLS** (OpenSSL *or* GnuTLS) plus **OpenSSL** for
certificate generation, and CMake.

### MacPorts (Intel / universal builds)

```bash
sudo port install cmake openssl LibVNCServer tigervnc
# For a single universal .app (recommended on Apple Silicon with MacPorts):
sudo port install cmake +universal openssl +universal LibVNCServer +universal
```

MacPorts `LibVNCServer` uses **GnuTLS** (`WITH_OPENSSL=OFF`). That is supported.

### Homebrew (Apple Silicon native)

```bash
brew install cmake openssl libvncserver
# Viewer (optional): brew install --cask tigervnc-viewer
```

Homebrew `libvncserver` uses **OpenSSL**. Confirm:

```bash
grep LIBVNCSERVER_HAVE_LIBSSL "$(brew --prefix libvncserver)/include/rfb/rfbconfig.h"
# expect: #define LIBVNCSERVER_HAVE_LIBSSL 1
```

## Configure & build

CMake searches `/opt/local` (MacPorts), `/opt/homebrew`, and `/usr/local`.

### Universal app (arm64 + x86_64) — default when deps are fat

Requires **fat/universal** LibVNCServer and OpenSSL. Prefer building with
**MacPorts `+universal`** (on Apple Silicon or a machine that can produce both
slices). Homebrew bottles are usually single-arch; CMake will warn and fall
back to native.

A binary that must **run on macOS 15 Intel** should be built against MacPorts
libraries on a macOS 15 (or compatible) SDK — not against Homebrew bottles
built for macOS 26/27.

```bash
cmake -S . -B build \
  -DCMAKE_PREFIX_PATH=/opt/local \
  -DMACVNC_UNIVERSAL=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build
# or: ./scripts/build-universal.sh
lipo -info build/macVNC.app/Contents/MacOS/macVNC
# expect: Architectures in the fat file: ... x86_64 arm64
```

### Native-only (when deps are single-arch, e.g. Homebrew arm64)

```bash
cmake -S . -B build -DMACVNC_UNIVERSAL=OFF
cmake --build build
```

### Lipo two machine-local builds

If you build arm64 on Apple Silicon (Homebrew) and x86_64 on Intel (MacPorts):

```bash
# on each machine:
cmake -S . -B build -DMACVNC_UNIVERSAL=OFF && cmake --build build
# copy both binaries together, then:
lipo -create -output macVNC.universal \
  macVNC.arm64 macVNC.x86_64
```

You must also ship matching-arch (or fat) copies of linked dylibs, or use
`cmake --install` / `fixup_bundle` per slice. Prefer MacPorts `+universal` when
you want one self-contained universal `.app`.

### Make / Ninja / ccache

A thin `Makefile` wraps CMake:

```bash
make                              # configure + build (Unix Makefiles)
make GENERATOR=Ninja              # faster incremental builds
make UNIVERSAL=OFF                # native arch (Homebrew)
make test                         # CTest unit tests
make COVERAGE=ON coverage         # LLVM coverage + lcov/HTML under build/
make format-check                 # clang-format on maintained sources
make tidy                         # clang-tidy via compile_commands.json
```

`ccache` is used automatically when present (`brew install ccache`). Disable with
`-DMACVNC_USE_CCACHE=OFF`.

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

**Homebrew cask (newer):**

```bash
/Applications/TigerVNC.app/Contents/MacOS/vncviewer \
  -X509CA "$HOME/.macvnc/cert.pem" host::5901
```

**MacPorts (often 1.14.x):**

```bash
/opt/local/bin/vncviewer -X509CA "$HOME/.macvnc/cert.pem" host::5901
# If an older viewer picks plain VncAuth, force:
/opt/local/bin/vncviewer -SecurityTypes=X509Vnc -X509CA "$HOME/.macvnc/cert.pem" host::5901
```

`/opt/local/bin/vncviewer` is a wrapper around
`/Applications/MacPorts/TigerVNC Viewer.app`. That app is **unsigned**; on
macOS 15+ Sequoia, Local Network privacy can reject it with **No route to
host** when launched from the console (SSH/`nc` may still work). Ad-hoc sign
once, then allow Local Network when prompted:

```bash
sudo codesign --force --deep --sign - "/Applications/MacPorts/TigerVNC Viewer.app"
open -a "/Applications/MacPorts/TigerVNC Viewer.app" --args host::5901
```

Confirm **TigerVNC Viewer** is enabled under System Settings → Privacy &
Security → Local Network. Re-run `codesign` after a MacPorts `tigervnc`
upgrade if the symptom returns.

(Recent macVNC builds hide stock VncAuth in encrypted mode so MacPorts 1.14
should prefer VeNCrypt without the extra flag.)

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

OCMock is reserved for future ScreenCapturer isolation tests (`brew install
ocmock` when adding those).

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
