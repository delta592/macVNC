/*
 * Optional low-overhead aggregated metrics for the capture/publish path.
 * Disabled by default; enable with -metrics (or MACVNC_METRICS=1).
 */
#ifndef MACVNC_METRICS_H
#define MACVNC_METRICS_H

#include <rfb/rfb.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t framesSubmitted;
    uint64_t framesSuperseded;
    uint64_t framesPublished;
    uint64_t fullFramePublishes;
    uint64_t dirtyTiles;
    uint64_t dirtyPixels;
    uint64_t bytesCopied;
    uint64_t captureWaitNs; /* time capture spent waiting on handoff mutex */
    uint64_t publishWaitNs; /* time publisher spent waiting for sendMutex */
    uint64_t copyDiffNs;
    uint64_t lastFrameAgeNs; /* capture→publish age of last published frame */
    uint64_t maxFrameAgeNs;
    uint64_t pendingPeak;
} MacVNCMetricsSnapshot;

void macvncMetricsSetEnabled(rfbBool enabled);
rfbBool macvncMetricsEnabled(void);

void macvncMetricsNoteSubmit(uint64_t captureWaitNs, rfbBool superseded, uint64_t pendingCount);
void macvncMetricsNotePublish(uint64_t frameAgeNs, uint64_t publishWaitNs, uint64_t copyDiffNs,
                              uint64_t dirtyTiles, uint64_t dirtyPixels, uint64_t bytesCopied,
                              rfbBool fullFrame);

void macvncMetricsSnapshot(MacVNCMetricsSnapshot *out);
void macvncMetricsLogSummary(const char *tag);

/* Monotonic nanoseconds (mach_absolute_time based). */
uint64_t macvncNowNs(void);

#ifdef __cplusplus
}
#endif

#endif /* MACVNC_METRICS_H */
