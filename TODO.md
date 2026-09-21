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

## Deviations from upstream

| Area | Change |
|------|--------|
| Security | In-tree VeNCrypt server handler (`src/vencrypt.c`). LibVNCServer 0.9.x only implements VeNCrypt on the **client**; the plan’s “just enable it” assumption does not hold for the server. Stock VncAuth/None types are neutered in encrypted mode so TigerVNC 1.14 does not prefer plain auth. |
| TLS I/O | Uses libvncserver’s `cl->sslctx` path (compiled when WebSockets+OpenSSL are enabled — true for Homebrew’s bottle). |
| Certs | Auto-generated self-signed cert on first run (`src/cert_manager.c`). |
| CLI | `-security {vencrypt\|anontls\|plain}`, `-regen-cert`. |
| Default posture | Encrypted modes refuse unencrypted VNC-auth attempts via a password-check gate. |

## Dependency notes

- **Homebrew** `libvncserver`: OpenSSL + WebSockets (`LIBVNCSERVER_HAVE_LIBSSL`).
- **MacPorts** `LibVNCServer`: GnuTLS + WebSockets (`LIBVNCSERVER_HAVE_GNUTLS`,
  `WITH_OPENSSL=OFF`). VeNCrypt X.509 uses `rfbssl_init` so both backends work.
- OpenSSL is always linked for certificate generation (`cert_manager.c`).
- Universal builds need fat deps (`port install … +universal`) or a lipo of two
  single-arch builds; see README.

## Still open (later phases)

- [ ] Phase 5: TigerVNC e2e + packet-capture verification
- [ ] Phase 5: Remmina (or second VeNCrypt client) check
- [ ] Phase 6: Permission UX polish / packaging / signing
- [ ] Phase 6: Expand LaunchAgent beyond the contrib plist (login-item UX)
- [ ] Phase 7: ScreenCaptureKit tuning / upstream PR
- [ ] Tests: OCMock-based ScreenCapturer isolation tests
- [ ] CI: enable Codecov upload (add `CODECOV_TOKEN` repo secret)
