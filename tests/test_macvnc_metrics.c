#include "macvnc_metrics.h"
#include "test_harness.h"

#include <string.h>

static void
test_disabled_is_noop(void)
{
    MacVNCMetricsSnapshot snap;

    macvncMetricsSetEnabled(FALSE);
    MACVNC_CHECK(!macvncMetricsEnabled());
    macvncMetricsNoteSubmit(100, TRUE, 2);
    macvncMetricsNotePublish(50, 10, 20, 3, 100, 400, TRUE);
    memset(&snap, 0xff, sizeof(snap));
    macvncMetricsSnapshot(&snap);
    /* Snapshot still copies current counters; enable(FALSE) does not clear unless
     * we re-enable. Re-enable with TRUE clears. */
    macvncMetricsSetEnabled(TRUE);
    MACVNC_CHECK(macvncMetricsEnabled());
    macvncMetricsSnapshot(&snap);
    MACVNC_CHECK(snap.framesSubmitted == 0);
    MACVNC_CHECK(snap.framesPublished == 0);
}

static void
test_submit_and_publish_aggregate(void)
{
    MacVNCMetricsSnapshot snap;

    macvncMetricsSetEnabled(TRUE);
    macvncMetricsNoteSubmit(10, FALSE, 1);
    macvncMetricsNoteSubmit(20, TRUE, 3);
    macvncMetricsNotePublish(1000, 5, 15, 4, 64, 256, FALSE);
    macvncMetricsNotePublish(2000, 7, 9, 8, 128, 512, TRUE);

    macvncMetricsSnapshot(&snap);
    MACVNC_CHECK(snap.framesSubmitted == 2);
    MACVNC_CHECK(snap.framesSuperseded == 1);
    MACVNC_CHECK(snap.pendingPeak == 3);
    MACVNC_CHECK(snap.captureWaitNs == 30);
    MACVNC_CHECK(snap.framesPublished == 2);
    MACVNC_CHECK(snap.fullFramePublishes == 1);
    MACVNC_CHECK(snap.dirtyTiles == 12);
    MACVNC_CHECK(snap.dirtyPixels == 192);
    MACVNC_CHECK(snap.bytesCopied == 768);
    MACVNC_CHECK(snap.publishWaitNs == 12);
    MACVNC_CHECK(snap.copyDiffNs == 24);
    MACVNC_CHECK(snap.lastFrameAgeNs == 2000);
    MACVNC_CHECK(snap.maxFrameAgeNs == 2000);

    macvncMetricsLogSummary("unit");
    macvncMetricsSetEnabled(FALSE);
}

static void
test_now_ns_monotonic(void)
{
    uint64_t a = macvncNowNs();
    uint64_t b = macvncNowNs();
    MACVNC_CHECK(b >= a);
}

static void
test_null_snapshot_and_log(void)
{
    macvncMetricsSetEnabled(TRUE);
    macvncMetricsNoteSubmit(1, FALSE, 0);
    macvncMetricsSnapshot(NULL); /* no-op */
    macvncMetricsLogSummary(NULL);
    macvncMetricsLogSummary("null-tag-ok");
    macvncMetricsSetEnabled(FALSE);
    macvncMetricsLogSummary("disabled");
}

int
main(void)
{
    test_disabled_is_noop();
    test_submit_and_publish_aggregate();
    test_now_ns_monotonic();
    test_null_snapshot_and_log();
    return macvncTestFinish("macvnc_metrics");
}
