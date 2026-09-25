# macVNC performance remediation plan

## Objective and scope

Reduce visible typing, pointer, and window-drag latency at 3200×1800 while retaining VeNCrypt/X.509 encryption. Target responsiveness comparable to the user's RealVNC baseline, but measure the gap rather than promise parity. This document is an implementation plan; no source or installed application changes have been made.

Source reviewed: delta592/macVNC commit `590310402f0de602c83f4bbf09a7d654c61ea0dc`, plus its pinned LibVNCServer 0.9.15 event loop. Confirm the installed build's provenance and current repository revision before implementation.

## Evidence and limitations

- `/tmp/macvnc-performance.txt`: ZRLE output path dominates approximately 78% of output-thread samples. Capture frequently waits for the client send mutex.
- `/tmp/macvnc-performance01.txt`: Hextile framebuffer processing occupies approximately 72% of output-thread samples, including approximately 6% in the TLS/socket write path. Pixel translation alone accounts for approximately 19%. Capture mutex waits appear in 3,872 of 8,470 sampling ticks, approximately 46% of the interval. Input spends approximately 99% waiting for socket activity.
- Hextile substantially improved perceived response; reducing `-deferupdate` did not.
- `src/mac.m` marks the entire framebuffer modified after each capture. Its capture callback takes every client's `sendMutex` before publishing the framebuffer. LibVNCServer holds that mutex during encoding and transmission.
- The cursor is included in capture, and `rfbScreen->cursor` is NULL.
- `src/ScreenCapturer.m` configures capture for up to 60 FPS and exposes no capture scaling or FPS controls.
- The dependency build disables JPEG and the observed binary rejects Tight encoding.
- A separate crash report, `/Users/dax/Library/Logs/DiagnosticReports/macVNC-2026-09-25-161339.ips`, faults in `ssl3_pending → SSL_pending → webSocketsHasDataInBuffer → clientInput`.

Sampling percentages describe stack occupancy, not measured frame latency, exact CPU utilization, or achieved FPS. The recordings use different interactive workloads and cannot establish a precise speedup. They identify encoding and capture synchronization as priorities; they do not exclude viewer or network latency. The crash stack identifies a path to investigate, not a proven root cause.

## 1. Establish repeatable measurements

Files: `src/mac.m`, `src/ScreenCapturer.m`, optional new metrics module, and `tests/`.

1. Reproduce the current behavior with a Release build and record commit, dependencies, architecture, display pixel dimensions, viewer version/settings, transport, and network conditions.
2. Add optional low-overhead, aggregated metrics or signposts for capture arrival, source-frame age, copy/diff duration, publication wait, encoding duration, socket-write duration, dirty pixel count, bytes sent, and frames superseded. Do not log keystroke contents or one line per frame.
3. Instrument LibVNCServer at explicit update boundaries if application hooks cannot provide reliable encoding/write timings. Keep any dependency patch small and versioned.
4. Run the same workloads: idle desktop; repeated typing in a plain text editor; pointer movement; repeated window dragging; scrolling text; a high-motion scene. Include one deliberately slow client.
5. Measure input-to-visible-result latency externally, such as timestamped test content plus high-frame-rate recording of local and remote screens. Internal timestamps alone do not measure viewer presentation latency.
6. Capture CPU samples and network throughput alongside latency. Use Hextile as the initial diagnostic baseline, then repeat with ZRLE.

Deliverable: baseline table containing median/p95 visible latency, frame age, delivered FPS, bytes/s, dirty-area ratio, CPU, memory, and capture lock waits.

## 2. Decouple capture from encoding safely

Files: `src/ScreenCapturer.m`, `src/mac.m`; preferably a small new frame-pipeline module with explicit ownership.

Implement a bounded latest-frame handoff before changing encoding algorithms:

- Capture callbacks publish an owned frame or retained pixel buffer into a bounded pending slot and return promptly. Replacing a pending frame releases its resources. Do not queue an unbounded history of frames.
- A separate publisher consumes the latest available frame and performs framebuffer updates. It may initially retain the existing encoder exclusion mechanism, but capture must no longer wait on client send locks.
- Treat this as a staged improvement: moving the lock wait off capture reduces capture blockage but does not by itself remove encoder serialization or network-induced lag.
- Never overwrite a buffer an encoder may still read. Specify ownership states, generation numbers, retain/release rules, and shutdown behavior. A third buffer alone does not make concurrent access safe.
- Audit client iteration/lifetime: the existing separate iterations for lock and unlock can observe different client sets. Hold valid client references and use consistent lock ordering, with disconnect/reconnect tests.
- If slow-client tests show unacceptable coupling, introduce per-client immutable frame snapshots or an explicit LibVNCServer snapshot/acquire-release integration. Audit all framebuffer and scaled-screen readers before changing global pointer lifetimes. Avoid a casual global pointer swap or removal of locks.
- Re-fetch the newest pending frame after long publication waits where safe, rather than publishing an unnecessarily stale candidate.

Acceptance: bounded memory and pending-frame count; no sustained capture-callback waits on encoding/network I/O; no tearing, use-after-free, or deadlocks under slow-client and disconnect tests. Report publication waits separately from capture waits.

## 3. Track actual changed regions

Files: frame-pipeline module, `src/mac.m`, `src/ScreenCapturer.m`.

- Replace unconditional full-screen `rfbMarkRectAsModified` with bounded, coalesced dirty regions.
- First implement a correct row-stride-aware tile comparison against the last published framebuffer, for example 32×32 or 64×64 tiles. Benchmark tile sizes rather than fixing one arbitrarily.
- Check pixel-buffer frame status, dimensions, format, bytes per row, lock results, and allocation bounds. Copy row by row where strides differ. Do not assume width × height × 4 matches the source layout.
- Evaluate ScreenCaptureKit frame attachments for dirty-rectangle metadata supported by the deployment target; verify availability and coordinate semantics against Apple documentation before implementation. Use metadata as an optimization, with a correctness fallback.
- Important: capture metadata may describe changes since the preceding captured frame. If pending frames are dropped, union all intervening damage or compare the latest image against the last published image. Otherwise updates can disappear permanently.
- Preserve each client's unsent modified region until that client consumes it. A global published-frame comparison does not replace per-client damage accumulation.
- Clip, transform, and coalesce rectangles; bound rectangle count and fall back to full-frame updates for large damage. Full damage is also required for initial connections, geometry changes, or invalid reference state.
- Cache stable display dimensions instead of querying CoreGraphics repeatedly inside the hot callback; refresh them through explicit display-change handling.

Acceptance: static desktop causes no repeated full-frame encoding; a typed character damages only a small region; dropped intermediate frames, scrolling, overlapping rectangles, reconnects, and multi-client updates remain visually correct. Test padded rows and geometry changes.

## 4. Separate cursor presentation from framebuffer updates

Files: `src/ScreenCapturer.m`, pointer/cursor handling in `src/mac.m`.

- Disable capture of the cursor only once a functioning separate-cursor path exists.
- Use supported macOS mechanisms to acquire cursor shape/hotspot changes and advertise them through LibVNCServer cursor APIs. Investigate API/thread constraints before selecting the mechanism; do not assume querying an application-local cursor gives the system-wide cursor.
- Let compatible viewers render the pointer locally. Handle cursor position updates for locally driven motion without introducing a feedback loop for remote input.
- Preserve an explicit fallback for clients without cursor-shape support. Prevent missing or double cursors, and validate text/I-beam, resize, drag, hidden cursor, and hotspot behavior.
- Correctly map framebuffer pixels to macOS display coordinates on Retina/scaled displays, secondary displays, and displays with negative origins. Apply any capture scale to input coordinates consistently.
- Profile modern `CGEventCreateMouseEvent` injection versus the deprecated path, preserving button transitions, drags, double-clicks, and scroll behavior. This is secondary to visual-update work; current samples do not identify input injection as the dominant cost.

Acceptance: pointer-only movement does not cause full-screen capture/encoding traffic for supporting viewers, and local cursor motion remains responsive under heavy screen updates.

## 5. Reduce pixel conversion and expose bounded performance controls

Files: `src/mac.m`, `src/ScreenCapturer.m`, CLI parsing/help, README, tests.

- Investigate why Hextile invokes `rfbTranslateWithRGBTables32to32` despite a BGRA capture format and apparently compatible 32-bit client pixels. Compare negotiated endian flags, depth, channel maxima/shifts, and padding semantics.
- Set an accurate server pixel format; use a library-supported no-conversion path only when layouts truly match. Do not mislabel BGRA data or force a client format it cannot interpret. Validate channel order with color bars and gradients on Intel and Apple Silicon.
- Introduce clearly documented application options such as `-maxfps` and `-scale` (proposed names, not existing flags). Validate ranges and preserve aspect ratio. Consider 30 FPS as a benchmark candidate, not an assumed optimal default.
- Keep capture, published framebuffer dimensions, dirty coordinates, cursor hotspot, and input coordinate transforms consistent under scaling.
- Retain Hextile/ZRLE compatibility. Raw is a controlled LAN benchmark option, not a blanket recommendation at 3200×1800.
- Evaluate bundling libjpeg-turbo and enabling Tight/JPEG only after the pipeline fixes. Measure text quality, CPU, bandwidth, packaging, and licensing impact; don't make lossy encoding mandatory or assume enabling a build flag alone is sufficient.

Acceptance: compatible formats avoid unnecessary translation; incompatible formats render correctly; scale/FPS settings behave predictably and produce useful CPU/bandwidth tradeoffs.

## 6. Resolve TLS stability and negotiation defects

Files: `src/vencrypt.c`, `scripts/build-deps.sh`, versioned LibVNCServer patches if needed.

Treat this as a release blocker alongside performance work, not proof that encryption causes the observed lag:

- Reproduce the SSL_pending crash under simultaneous input/output, reconnects, disconnects during writes, and TLS handshakes. Audit SSL object ownership, lifetime, and concurrent calls from input/output threads against the pinned OpenSSL and LibVNCServer implementations.
- Check for premature destruction, stale references, and unsupported concurrent access before choosing a fix. Avoid adding a blocking global TLS mutex that creates input/output starvation or deadlocks.
- Replace the private-symbol handler mutation used to suppress unencrypted security types with supported library integration or an explicit maintained dependency patch. The current image-name search misses statically linked LibVNCServer.
- Ensure encrypted mode advertises only intended encrypted security types, correctly chooses X509None versus X509Vnc, and fails closed when enforcement cannot be established.
- Preserve certificate validation and encrypted transport throughout performance tests.

Acceptance: repeatable stress sessions complete without crashes; encrypted-only negotiation works in static release builds; no authentication regression or hidden unencrypted fallback.

## Implementation sequence and review boundaries

1. Metrics, reproducible benchmarks, and regression fixtures.
2. Bounded capture handoff, ownership/lifetime fixes, and stride/frame validation.
3. Changed-region tracking and dropped-frame correctness.
4. Separate cursor updates and coordinate mapping.
5. Pixel-format fast path and measured scale/FPS controls.
6. Optional additional encoders, only if measurements justify them.

Investigate TLS stability alongside these changes and complete its fix before release. Keep each change independently reviewable and benchmark it against the same baseline. Do not combine an unmeasured encoder switch with a concurrency rewrite in one change.

## Validation and proposed success criteria

Run existing tests plus focused tests for region merging, dropped-frame damage, stride handling, ownership, coordinate transforms, and disconnect races. Use sanitizers where compatible; do not use sanitizer builds for performance comparisons.

Benchmark Release builds at the original 3200×1800 resolution and at a reduced resolution, with Hextile and ZRLE, on controlled wired LAN and a representative wireless connection. Test one and multiple clients. Compare with RealVNC using the same screen content, resolution, and network.

Proposed targets to refine after baseline measurement:

- At least 50% reduction in p95 typing-to-visible latency versus current Hextile; aim for p95 below 100 ms on the reference wired LAN, with no claim of guaranteed RealVNC parity.
- Capture handoff p95 below one frame interval at the configured capture rate; no unbounded age or memory growth under overload.
- No full-frame invalidation for pointer-only motion with separate-cursor-capable clients; substantial dirty-area reduction for typing and static UI workloads.
- Smooth 30 FPS window motion where hardware/network permit, without worsening input latency; measure delivered FPS rather than configured FPS.
- At least 30 minutes of interactive/automated stress and repeated reconnect cycles without crash, deadlock, tearing, or stale regions.

Record failures and tradeoffs rather than relaxing correctness to hit a latency number. Ship measured results, updated CLI documentation, and a rollback path with the release.

## Source references

- https://github.com/delta592/macVNC/blob/590310402f0de602c83f4bbf09a7d654c61ea0dc/src/mac.m
- https://github.com/delta592/macVNC/blob/590310402f0de602c83f4bbf09a7d654c61ea0dc/src/ScreenCapturer.m
- https://github.com/delta592/macVNC/blob/590310402f0de602c83f4bbf09a7d654c61ea0dc/src/vencrypt.c
- https://github.com/delta592/macVNC/blob/590310402f0de602c83f4bbf09a7d654c61ea0dc/scripts/build-deps.sh
- https://github.com/LibVNC/libvncserver/blob/LibVNCServer-0.9.15/src/libvncserver/main.c
