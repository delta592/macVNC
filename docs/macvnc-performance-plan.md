# macVNC performance remediation plan

## Objective and scope

Reduce visible typing, pointer, and window-drag latency at 3200×1800 while retaining VeNCrypt/X.509 encryption. Target responsiveness comparable to the user's RealVNC baseline, but measure the gap rather than promise parity.

**Status (2026-09-25):** Core pipeline, dirty-region, cursor, pixel-format, CLI controls, and TLS reconnect fixes are implemented on branch `perf/capture-pipeline-remediation` and validated on **dauntlas** (2019 Intel iMac, macOS 15.8, x86_64) with TigerVNC over VeNCrypt. Hextile interactive response is reported as excellent; ZRLE remains usable but measurably heavier. Formal external p95 latency tables and optional Tight/JPEG are still open.

Baseline reviewed: commit `590310402f0de602c83f4bbf09a7d654c61ea0dc` + LibVNCServer 0.9.15. Runtime validation used a universal Release build that includes LibVNC patch rev `p1` (SSL mutex + `rfbDisableBuiltinSecurityTypes`).

## Evidence and limitations

### Pre-fix samples (old `/Applications` binary)

- [x] `docs/macvnc-performance.txt` (ZRLE): output-path encode/zlib dominates; capture frequently waits on client `sendMutex`.
- [x] `docs/macvnc-performance01.txt` (Hextile): framebuffer encode ~72% of output-thread samples; ~19% pixel translate; capture mutex waits ~3872 samples (~46% of interval).
- [x] Hextile improved perceived response vs ZRLE; reducing `-deferupdate` did not.
- [x] Crash `macVNC-2026-09-25-161339.ips`: `ssl3_pending → SSL_pending → webSocketsHasDataInBuffer → clientInput`.

### Post-fix samples (Downloads universal build with pipeline)

- [x] `docs/macvnc-performance02.txt` (Hextile): capture mutex waits ~6 (was ~3872); Hextile leaf ~319 (was ~3701); translate leaf **0**; publisher idle on condvar.
- [x] `docs/macvnc-performance03.txt` (ZRLE): still much better than old ZRLE, but zlib/ZRLE leaf CPU and `sendMutex` waits remain higher than Hextile — matches felt lag.
- [x] Repeated TigerVNC disconnect/reconnect no longer segfaults.

Sampling percentages describe stack occupancy, not measured viewer presentation latency. Workloads differed across recordings.

## 1. Establish repeatable measurements

Files: `src/macvnc_metrics.*`, `src/mac.m`, `tests/`.

- [x] Reproduce with Release/universal builds on the Intel host; record samples under `docs/macvnc-performance*.txt`.
- [x] Add optional aggregated metrics (`-metrics` / `MACVNC_METRICS=1`) for submit/supersede/publish, capture wait, publish wait, copy/diff, dirty tiles/pixels, frame age — no per-keystroke or per-frame spam.
- [ ] Instrument LibVNCServer encode/socket-write boundaries (optional; app-level metrics + `sample` were sufficient for the first remediation).
- [x] Run interactive workloads (typing, pointer, window drag) under Hextile and ZRLE with VeNCrypt.
- [ ] External input-to-visible latency (high-frame-rate dual-screen recording / timed test content) with median/p95 table.
- [x] Capture CPU samples alongside interactive testing (before/after Hextile + after ZRLE).

**Deliverable:** informal before/after sample comparison done; formal baseline table (p95 visible latency, FPS, bytes/s, etc.) still open.

## 2. Decouple capture from encoding safely

Files: `src/frame_pipeline.*`, `src/mac.m`, `src/ScreenCapturer.m`.

- [x] Bounded latest-frame pending slot; superseded frames drop prior pending content.
- [x] Separate publisher thread; capture no longer waits on client `sendMutex`.
- [x] Double-buffer publish under brief, consistent client locking with `rfbIncrClientRef` / matching unlock set.
- [x] Stride-aware copy into the pending buffer; validate CVPixelBuffer format/size before submit.
- [x] Re-check for a newer pending frame after preparing a candidate (avoid publishing stale frames after long waits where safe).
- [x] Disconnect/reconnect exercised manually with TigerVNC (no capture/publish deadlock observed).
- [ ] Per-client immutable snapshots if a slow client still couples too hard (not required yet on wired LAN).
- [ ] Longer automated stress (30+ minutes) and multi-client tests.

**Acceptance (observed):** capture mutex contention effectively gone in Hextile sample; no tearing reported; reconnect works.

## 3. Track actual changed regions

Files: `src/frame_pipeline.*`, `src/mac.m`.

- [x] Replace unconditional full-screen `rfbMarkRectAsModified` with tile diff + coalesced rects (default tile **64**; CLI `-tile-size 32|64`).
- [x] Row-stride-aware compare/copy; do not assume packed `width*height*4` from the CVPixelBuffer.
- [x] Use `SCStreamFrameInfoDirtyRects` as a hint when present; on dropped pending frames ignore stale hints and full-compare against last published.
- [x] Rely on LibVNC per-client modified regions after mark; force full damage on new client connect.
- [x] Bound coalesced rect count / dirty ratio → full-frame fallback.
- [x] Cache display/framebuffer dimensions for the hot path (scale applied at init).
- [x] Unit tests for tile diff / coalesce overflow (`tests/test_frame_pipeline.c`).
- [ ] Explicit display-reconfiguration / geometry-change handler beyond initial setup.
- [ ] Dedicated multi-client and padded-stride device matrix beyond dauntlas.

**Acceptance (observed):** static UI / typing no longer drives full-frame Hextile cost in samples; interactive feel matches.

## 4. Separate cursor presentation from framebuffer updates

Files: `src/cursor_tracker.*`, `src/ScreenCapturer.m`, `src/mac.m`.

- [x] Disable SCK cursor compositing (`showsCursor=NO`) once rich-cursor path exists.
- [x] Publish cursor shape via LibVNC rich cursor (`NSCursor` → BGRA + **mask from alpha**).
- [x] Map framebuffer ↔ display coordinates with origin + `-scale`; suppress local cursor echo briefly after remote `PtrAddEvent`.
- [x] Fixed NULL `mask` segfault in `rfbSendCursorShape` on first client framebuffer update.
- [ ] Exhaustive cursor-shape matrix (I-beam, resize, drag, hidden) on secondary/negative-origin displays.
- [ ] Profile `CGEventCreateMouseEvent` vs deprecated `CGPostMouseEvent` (still secondary).

**Acceptance (observed):** pointer motion responsive; no cursor-send crash after mask fix; supporting viewers use local cursor rendering.

## 5. Reduce pixel conversion and expose bounded performance controls

Files: `src/mac.m`, `src/ScreenCapturer.m`, README, CLI help.

- [x] Set explicit LE BGRA server format (`depth=24`, shifts, `bigEndian=FALSE`); post-fix Hextile sample shows **0** `rfbTranslateWithRGBTables32to32` leaves.
- [x] CLI: `-maxfps` (default **30**), `-scale` (0.25–1.0), `-tile-size`, `-metrics`.
- [x] Keep capture size, FB size, dirty coords, and pointer mapping consistent under scale.
- [x] Retain Hextile/ZRLE; recommend Hextile for interactive LAN on Intel.
- [ ] Color-bar / gradient validation pass on both Intel and Apple Silicon viewers.
- [ ] Evaluate libjpeg-turbo / Tight only if measurements justify (deferred; pipeline first).

**Acceptance (observed):** no unnecessary translation in Hextile sample; FPS/scale knobs documented and used on dauntlas.

## 6. Resolve TLS stability and negotiation defects

Files: `src/vencrypt.c`, `scripts/build-deps.sh`, `patches/libvncserver-0.9.15/`.

- [x] Reproduce disconnect/reconnect crash; root cause concurrent SSL use / teardown (`SSL_pending` on bad/freed state).
- [x] Versioned LibVNC patch: per-`sslctx` mutex around SSL I/O + null-safe `pending`/`destroy`.
- [x] Replace dyld private-symbol neutering with `rfbDisableBuiltinSecurityTypes()` from the same patch (works with static link).
- [x] AnonTLS OpenSSL ctx layout matches patched `rfbssl_openssl.c` (mutex fields).
- [x] Manual reconnect loops with TigerVNC + VeNCrypt succeed after the fix.
- [ ] Extended automated TLS stress (handshakes during writes, multi-hour soak).
- [ ] Confirm fail-closed advertising on a clean install without relying on viewer `-SecurityTypes` overrides.

**Acceptance (observed):** reconnect no longer segfaults; encrypted sessions used throughout post-fix samples.

## Implementation sequence (checklist)

1. [x] Metrics + reproducible `sample` benchmarks (formal p95 table optional follow-up).
2. [x] Bounded capture handoff, ownership/lifetime, stride/frame validation.
3. [x] Changed-region tracking and dropped-frame correctness.
4. [x] Separate cursor updates and coordinate mapping (mask fix included).
5. [x] Pixel-format fast path and `-maxfps` / `-scale` controls.
6. [ ] Optional additional encoders (Tight/JPEG) — only if needed after measurement.
7. [x] TLS stability fix before release candidate packaging (`make dist`).

## Validation and success criteria

- [x] Existing CTest + new frame-pipeline tests.
- [x] Release universal build on 3200×-class Intel display; Hextile and ZRLE over VeNCrypt on wired LAN.
- [x] Qualitative: Hextile typing/pointer/window updates “extremely good / highly responsive.”
- [x] Sample-based: ≥ order-of-magnitude drop in capture mutex waits and Hextile leaf cost vs pre-fix Hextile.
- [x] Repeated client reconnect without crash.
- [ ] Formal p95 typing-to-visible &lt; 100 ms claim (needs external measurement).
- [ ] 30-minute automated stress + multi-client matrix.
- [ ] Sanitizer builds where compatible (not for perf compares).
- [ ] Side-by-side RealVNC latency capture under identical content/network.

## Packaging / build notes

- [x] `make universal` / `make dist` produce fat `arm64+x86_64` apps via `build-universal/`.
- [x] `make scrub` wipes `build/`, `build-universal/`, `deps/`, and `dist/` for a clean rebuild.
- [x] LibVNC patches applied from `patches/libvncserver-0.9.15/` during `scripts/build-deps.sh` (stamp `…-p1`).

## Source references

- In-tree (post-remediation): `src/mac.m`, `src/ScreenCapturer.m`, `src/frame_pipeline.*`, `src/cursor_tracker.*`, `src/macvnc_metrics.*`, `src/vencrypt.c`, `scripts/build-deps.sh`, `patches/libvncserver-0.9.15/`
- Baseline commit tree: https://github.com/delta592/macVNC/blob/590310402f0de602c83f4bbf09a7d654c61ea0dc/src/mac.m
- LibVNCServer 0.9.15: https://github.com/LibVNC/libvncserver/blob/LibVNCServer-0.9.15/src/libvncserver/main.c
