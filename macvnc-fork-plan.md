# Plan: Fork macVNC → Native macOS VNC Server with Built-In Encryption

**Goal:** A native macOS VNC server (no X11) with negotiated traffic encryption
(AES via TLS/VeNCrypt), paired with an existing encryption-capable viewer
(e.g. TigerVNC Viewer) — no SSH tunneling required.

**Starting point:** [LibVNC/macVNC](https://github.com/LibVNC/macVNC) — the
official LibVNCServer macOS example, descended from OSXvnc. Already has
multi-threaded libvncserver integration, double-buffered framebuffer updates,
mouse/keyboard input injection, and multi-monitor support. GPLv2 licensed.

---

## Phase 0 — Groundwork

- [ ] Fork `LibVNC/macVNC` on GitHub to your own account/org.
- [ ] Clone locally, confirm it builds as-is:
  - Install deps via Homebrew: `brew install libvncserver cmake`
  - `mkdir build && cd build && cmake .. && cmake --build .`
- [ ] Run the stock build, connect with Screen Sharing or an existing VNC
      viewer, confirm baseline functionality (mouse, keyboard, multi-monitor)
      works on your machine before changing anything.
- [ ] Read the GPLv2 license terms carefully and decide now whether this stays
      open source or whether that's a blocker for your intended use —
      changing your mind later is much harder than deciding up front.
- [ ] Set up a private issue tracker or a `TODO.md` in the fork to track
      deviations from upstream (makes rebasing/pulling upstream fixes easier
      later).

## Phase 1 — Audit the Existing Codebase

Before adding anything, understand what's actually there:

- [ ] Identify which screen-capture API the code currently uses (likely an
      older `CGDisplayCreateImage`/`CGWindowListCreateImage`-era approach
      given its OSXvnc lineage). Note the file(s) involved.
- [ ] Identify the input-injection code path (should be `CGEventPost`-based
      already) and confirm what permissions it requests and when.
- [ ] Check how libvncserver is currently initialized (`rfbGetScreen` /
      `rfbInitServer` call site) — this is where the new security type gets
      registered later.
- [ ] Reproduce the known open issue around password authentication not
      working reliably with some clients (referenced in the project's GitHub
      issues) so you understand whether it affects your target auth path.
- [ ] Decide whether the existing capture approach is "good enough to ship"
      or whether it's worth modernizing to ScreenCaptureKit as a separate,
      later phase — don't conflate this with the encryption work.

## Phase 2 — Rebuild libvncserver with TLS Support

The encryption capability already exists in libvncserver itself; you're
enabling it, not writing it.

- [ ] Confirm your installed libvncserver was built with a crypto backend
      enabled. Homebrew's default build may or may not have
      `WITH_OPENSSL=ON` — check, and rebuild from source with CMake flags if
      not:
      ```
      cmake .. -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF
      ```
- [ ] Verify the built library actually exposes VeNCrypt support (check for
      `rfbVeNCrypt` and related symbols in the installed headers).
- [ ] Update macVNC's own `CMakeLists.txt` / build config to link against
      this TLS-enabled libvncserver build, and document the dependency
      clearly in the README so future-you (or contributors) don't
      accidentally build against a stock Homebrew version without crypto.

## Phase 3 — Certificate Handling

VeNCrypt over TLS needs a certificate; the goal is "zero manual setup" like
RealVNC's experience.

- [ ] Decide storage location for a self-signed cert/key pair (e.g.
      `~/Library/Application Support/macVNC/`).
- [ ] Add first-run logic: if no cert exists, generate a self-signed
      cert/key pair automatically (OpenSSL CLI invocation or OpenSSL C API
      call at startup).
- [ ] Set appropriate file permissions on the private key (owner-read-only).
- [ ] Add a way to view/regenerate the cert later (a `--regen-cert` flag or
      similar), in case it's ever compromised or expires.
- [ ] Optional: support an "AnonTLS" fallback mode (no cert, anonymous
      Diffie-Hellman) for a truly zero-config first run, with a clear log
      message noting the server identity isn't authenticated in that mode.

## Phase 4 — Wire VeNCrypt into the Server Init

This is the actual code change, and it should be small.

- [ ] At the `rfbGetScreen`/`rfbInitServer` call site, register the
      VeNCrypt security type alongside (or instead of) the existing plain
      VNC auth.
- [ ] Point libvncserver at the cert/key files generated in Phase 3.
- [ ] Add a command-line flag or config option to toggle between:
      - VeNCrypt with X.509 cert (default, once Phase 3 is solid)
      - AnonTLS (no cert)
      - Legacy plain VNC auth (for compatibility testing / fallback only —
        clearly labeled as unencrypted)
- [ ] Add a startup log line stating which security mode is active, so
      it's never ambiguous whether a session is encrypted.

## Phase 5 — Testing Against Real Viewers

- [ ] Install TigerVNC Viewer (`brew install --cask tigervnc-viewer`) as
      your primary test client.
- [ ] Confirm a full connect → authenticate → TLS handshake → framebuffer
      update cycle works end-to-end.
- [ ] Use a packet capture (Wireshark on loopback or a spare interface) to
      confirm the actual RFB payload is encrypted post-handshake — don't
      just trust that the security type negotiation succeeded.
- [ ] Test against at least one other VeNCrypt-capable client if available
      (e.g. Remmina) to confirm you haven't accidentally built something
      TigerVNC-specific.
- [ ] Test the "no cert yet" first-run path on a clean machine/user account
      to make sure cert generation actually triggers correctly.
- [ ] Re-test mouse/keyboard input and multi-monitor behavior — confirm
      nothing in the encryption changes broke the existing functionality
      from Phase 0.

## Phase 6 — Permissions & Packaging

- [ ] Confirm Screen Recording and Accessibility permission prompts fire
      correctly and are clearly explained to the end user (a first-run
      dialog or README section, not just a silent TCC prompt).
- [ ] Decide on distribution shape: raw CLI binary, a minimal `.app`
      wrapper (mentioned as already supported by macVNC's build/CI), or a
      LaunchAgent/LaunchDaemon for background operation.
- [ ] If distributing outside your own machine, address code signing and
      notarization — unsigned binaries needing Accessibility/Screen
      Recording permissions get a rougher Gatekeeper experience.
- [ ] Add Bonjour/mDNS advertisement if you want LAN auto-discovery
      matching the RealVNC-style experience (optional, not required for
      core functionality).

## Phase 7 — Longer-Term / Optional

- [ ] Evaluate migrating capture from the legacy API to ScreenCaptureKit
      for better performance and forward compatibility (separate effort
      from the encryption work — don't block on this).
- [ ] Consider upstreaming the VeNCrypt support back to `LibVNC/macVNC` as
      a pull request — it benefits from GPLv2's copyleft either way, and
      the maintainers may welcome it.
- [ ] Revisit auth options (SASL, Apple ARD-style DH) only if you have a
      specific interoperability need — VeNCrypt alone satisfies the
      original "no SSH tunnel, AES-encrypted" goal.

---

## Definition of Done

A build of your fork that:
1. Runs natively on macOS with no X11/XQuartz dependency.
2. Refuses (or clearly flags) unencrypted connections by default.
3. Successfully completes a VeNCrypt/TLS handshake with TigerVNC Viewer.
4. Confirmed via packet capture to be encrypting the RFB payload.
5. Retains all pre-existing mouse/keyboard/multi-monitor functionality.
