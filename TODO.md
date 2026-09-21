# macVNC Fork — Deviations & TODO

Tracking differences from upstream [LibVNC/macVNC](https://github.com/LibVNC/macVNC)
and from `macvnc-fork-plan.md`.

## Decisions

- **License:** GPLv2 retained. Private use on own machines only; no redistribution planned.
- **Default security:** VeNCrypt + X.509 self-signed cert.
- **AnonTLS:** Available via `-security anontls`.
- **Cert storage:** `~/.macvnc/{cert,key}.pem` (changed from Application Support —
  TigerVNC `-X509CA` cannot use paths with spaces).
- **Capture:** Already on ScreenCaptureKit upstream — leave as-is (no Phase 7 work yet).
- **Dependencies:** Built from source via `scripts/build-deps.sh` (OpenSSL +
  LibVNCServer, per-arch then `lipo`). No Homebrew/MacPorts link deps.

## Deviations from upstream

| Area | Change |
|------|--------|
| Security | In-tree VeNCrypt server handler (`src/vencrypt.c`). LibVNCServer 0.9.x only implements VeNCrypt on the **client**; the plan’s “just enable it” assumption does not hold for the server. Stock VncAuth/None types are neutered in encrypted mode so TigerVNC 1.14 does not prefer plain auth. |
| TLS I/O | Uses libvncserver’s `cl->sslctx` path (compiled when WebSockets+OpenSSL are enabled). |
| Certs | Auto-generated self-signed cert on first run (`src/cert_manager.c`); key `0600`, cert `0644` via `open`+`fchmod`. |
| CLI | `-security {vencrypt\|anontls\|plain}`, `-regen-cert`. |
| Default posture | Encrypted modes refuse unencrypted VNC-auth attempts via a password-check gate. |
| Build | `scripts/build-deps.sh` builds static OpenSSL + LibVNCServer per arch and merges universal libs; CMake does not search package-manager prefixes. |

## Dependency notes

- OpenSSL (pinned in `build-deps.sh`) is linked for TLS in LibVNCServer and for
  certificate generation (`cert_manager.c`).
- LibVNCServer is built with `-DWITH_OPENSSL=ON -DWITH_WEBSOCKETS=ON`
  (`LIBVNCSERVER_HAVE_LIBSSL` + `LIBVNCSERVER_WITH_WEBSOCKETS`).
- JPEG/PNG encoders are disabled in the from-source LibVNCServer build to avoid
  extra third-party libraries; zlib comes from the macOS SDK.
- Universal builds: `./scripts/build-deps.sh` then
  `./scripts/build-universal.sh` (or `make universal`).

## Still open (later phases)

- [ ] Phase 5: TigerVNC e2e + packet-capture verification
- [ ] Phase 5: Remmina (or second VeNCrypt client) check
- [ ] Phase 6: Permission UX polish / packaging / signing
- [ ] Phase 6: Expand LaunchAgent beyond the contrib plist (login-item UX)
- [ ] Phase 7: ScreenCaptureKit tuning / upstream PR
- [ ] Tests: OCMock-based ScreenCapturer isolation tests
- [ ] CI: enable Codecov upload (add `CODECOV_TOKEN` repo secret)
- [ ] CI: optional universal (arm64+x86_64) job via `build-deps.sh` without `--arch`
