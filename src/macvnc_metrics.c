#include "macvnc_metrics.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static rfbBool gEnabled = FALSE;
static MacVNCMetricsSnapshot gSnap;
static mach_timebase_info_data_t gTimebase;
static rfbBool gTimebaseReady = FALSE;

uint64_t
macvncNowNs(void)
{
    if (!gTimebaseReady) {
        mach_timebase_info(&gTimebase);
        gTimebaseReady = TRUE;
    }
    uint64_t t = mach_absolute_time();
    return t * gTimebase.numer / gTimebase.denom;
}

void
macvncMetricsSetEnabled(rfbBool enabled)
{
    pthread_mutex_lock(&gLock);
    gEnabled = enabled;
    if (enabled)
        memset(&gSnap, 0, sizeof(gSnap));
    pthread_mutex_unlock(&gLock);
}

rfbBool
macvncMetricsEnabled(void)
{
    rfbBool e;
    pthread_mutex_lock(&gLock);
    e = gEnabled;
    pthread_mutex_unlock(&gLock);
    return e;
}

void
macvncMetricsNoteSubmit(uint64_t captureWaitNs, rfbBool superseded, uint64_t pendingCount)
{
    if (!gEnabled)
        return;
    pthread_mutex_lock(&gLock);
    gSnap.framesSubmitted++;
    if (superseded)
        gSnap.framesSuperseded++;
    gSnap.captureWaitNs += captureWaitNs;
    if (pendingCount > gSnap.pendingPeak)
        gSnap.pendingPeak = pendingCount;
    pthread_mutex_unlock(&gLock);
}

void
macvncMetricsNotePublish(uint64_t frameAgeNs, uint64_t publishWaitNs, uint64_t copyDiffNs,
                         uint64_t dirtyTiles, uint64_t dirtyPixels, uint64_t bytesCopied,
                         rfbBool fullFrame)
{
    if (!gEnabled)
        return;
    pthread_mutex_lock(&gLock);
    gSnap.framesPublished++;
    if (fullFrame)
        gSnap.fullFramePublishes++;
    gSnap.publishWaitNs += publishWaitNs;
    gSnap.copyDiffNs += copyDiffNs;
    gSnap.dirtyTiles += dirtyTiles;
    gSnap.dirtyPixels += dirtyPixels;
    gSnap.bytesCopied += bytesCopied;
    gSnap.lastFrameAgeNs = frameAgeNs;
    if (frameAgeNs > gSnap.maxFrameAgeNs)
        gSnap.maxFrameAgeNs = frameAgeNs;
    pthread_mutex_unlock(&gLock);
}

void
macvncMetricsSnapshot(MacVNCMetricsSnapshot *out)
{
    if (!out)
        return;
    pthread_mutex_lock(&gLock);
    *out = gSnap;
    pthread_mutex_unlock(&gLock);
}

void
macvncMetricsLogSummary(const char *tag)
{
    MacVNCMetricsSnapshot s;
    if (!gEnabled)
        return;
    macvncMetricsSnapshot(&s);
    rfbLog("metrics[%s]: submitted=%llu superseded=%llu published=%llu full=%llu "
           "dirtyTiles=%llu dirtyPx=%llu bytes=%llu "
           "capWaitNs=%llu pubWaitNs=%llu copyDiffNs=%llu "
           "lastAgeNs=%llu maxAgeNs=%llu pendingPeak=%llu\n",
           tag ? tag : "-", (unsigned long long)s.framesSubmitted,
           (unsigned long long)s.framesSuperseded, (unsigned long long)s.framesPublished,
           (unsigned long long)s.fullFramePublishes, (unsigned long long)s.dirtyTiles,
           (unsigned long long)s.dirtyPixels, (unsigned long long)s.bytesCopied,
           (unsigned long long)s.captureWaitNs, (unsigned long long)s.publishWaitNs,
           (unsigned long long)s.copyDiffNs, (unsigned long long)s.lastFrameAgeNs,
           (unsigned long long)s.maxFrameAgeNs, (unsigned long long)s.pendingPeak);
}
