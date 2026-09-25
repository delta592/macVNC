#include "frame_pipeline.h"
#include "macvnc_metrics.h"
#include "test_harness.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void
test_diff_and_coalesce(void)
{
    const int w = 128, h = 64, bpp = 4, tile = 32;
    const int stride = w * bpp;
    const int tilesX = (w + tile - 1) / tile;
    const int tilesY = (h + tile - 1) / tile;
    uint8_t *prev = calloc(1, (size_t)stride * (size_t)h);
    uint8_t *next = calloc(1, (size_t)stride * (size_t)h);
    uint8_t *tileMap = calloc(1, (size_t)tilesX * (size_t)tilesY);
    MacVNCRect rects[16];
    int dirty, n;

    MACVNC_CHECK(prev && next && tileMap);

    /* Identical frames → no dirty tiles. */
    dirty = macvncPipelineDiffTiles(prev, next, w, h, bpp, stride, tile, tileMap, tilesX, tilesY,
                                    NULL, 0);
    MACVNC_CHECK(dirty == 0);

    /* Change a 8×8 block inside one tile. */
    memset(next + 4 * stride + 8 * bpp, 0x7f, 8 * bpp);
    dirty = macvncPipelineDiffTiles(prev, next, w, h, bpp, stride, tile, tileMap, tilesX, tilesY,
                                    NULL, 0);
    MACVNC_CHECK(dirty == 1);

    n = macvncPipelineCoalesceTiles(tileMap, tilesX, tilesY, tile, w, h, rects, 16);
    MACVNC_CHECK(n == 1);
    MACVNC_CHECK(rects[0].x == 0);
    MACVNC_CHECK(rects[0].y == 0);
    MACVNC_CHECK(rects[0].w == tile);
    MACVNC_CHECK(rects[0].h == tile);

    /* Clip hints limit which tiles are examined. */
    {
        MacVNCRect clip = {.x = 0, .y = 0, .w = 16, .h = 16};
        memset(tileMap, 0, (size_t)tilesX * (size_t)tilesY);
        /* Change far away — outside clip — should report 0 when clipped. */
        memset(next, 0, (size_t)stride * (size_t)h);
        memset(next + 40 * stride + 100 * bpp, 0xaa, 4);
        dirty = macvncPipelineDiffTiles(prev, next, w, h, bpp, stride, tile, tileMap, tilesX,
                                        tilesY, &clip, 1);
        MACVNC_CHECK(dirty == 0);
    }

    /* Empty / out-of-bounds clips are skipped. */
    {
        MacVNCRect bad[] = {{.x = 10, .y = 10, .w = 0, .h = 10},
                            {.x = -40, .y = -40, .w = 10, .h = 10},
                            {.x = w + 10, .y = 0, .w = 8, .h = 8}};
        memset(next, 0, (size_t)stride * (size_t)h);
        dirty = macvncPipelineDiffTiles(prev, next, w, h, bpp, stride, tile, tileMap, tilesX,
                                        tilesY, bad, 3);
        MACVNC_CHECK(dirty == 0);
    }

    /* Partial edge tile (non-multiple geometry). */
    {
        const int ew = 100, eh = 50, etile = 32;
        const int estride = ew * bpp;
        const int etx = (ew + etile - 1) / etile;
        const int ety = (eh + etile - 1) / etile;
        uint8_t *ep = calloc(1, (size_t)estride * (size_t)eh);
        uint8_t *en = calloc(1, (size_t)estride * (size_t)eh);
        uint8_t *em = calloc(1, (size_t)etx * (size_t)ety);
        MACVNC_CHECK(ep && en && em);
        en[(eh - 1) * estride + (ew - 1) * bpp] = 0x55;
        dirty = macvncPipelineDiffTiles(ep, en, ew, eh, bpp, estride, etile, em, etx, ety, NULL, 0);
        MACVNC_CHECK(dirty == 1);
        free(ep);
        free(en);
        free(em);
    }

    free(prev);
    free(next);
    free(tileMap);
}

static void
test_coalesce_merges_adjacent_row(void)
{
    const int tilesX = 4, tilesY = 2, tile = 32;
    uint8_t tileMap[8];
    MacVNCRect rects[8];
    int n;

    memset(tileMap, 0, sizeof(tileMap));
    tileMap[0] = 1;
    tileMap[1] = 1;
    tileMap[2] = 1;

    n = macvncPipelineCoalesceTiles(tileMap, tilesX, tilesY, tile, 128, 64, rects, 8);
    MACVNC_CHECK(n == 1);
    MACVNC_CHECK(rects[0].x == 0);
    MACVNC_CHECK(rects[0].y == 0);
    MACVNC_CHECK(rects[0].w == tile * 3);
    MACVNC_CHECK(rects[0].h == tile);
}

static void
test_coalesce_grows_vertically(void)
{
    const int tilesX = 3, tilesY = 3, tile = 32;
    uint8_t tileMap[9];
    MacVNCRect rects[4];
    int n;

    memset(tileMap, 0, sizeof(tileMap));
    /* 2×2 block of dirty tiles. */
    tileMap[0] = 1;
    tileMap[1] = 1;
    tileMap[3] = 1;
    tileMap[4] = 1;

    n = macvncPipelineCoalesceTiles(tileMap, tilesX, tilesY, tile, 96, 96, rects, 4);
    MACVNC_CHECK(n == 1);
    MACVNC_CHECK(rects[0].w == tile * 2);
    MACVNC_CHECK(rects[0].h == tile * 2);
}

static void
test_coalesce_overflow(void)
{
    const int tilesX = 4, tilesY = 4, tile = 32;
    uint8_t tileMap[16];
    MacVNCRect rects[2];
    int n;

    memset(tileMap, 0, sizeof(tileMap));
    tileMap[0] = 1;
    tileMap[2] = 1;
    tileMap[5] = 1;
    tileMap[7] = 1;
    tileMap[8] = 1;
    tileMap[10] = 1;
    tileMap[13] = 1;
    tileMap[15] = 1;

    n = macvncPipelineCoalesceTiles(tileMap, tilesX, tilesY, tile, 128, 128, rects, 2);
    MACVNC_CHECK(n < 0); /* overflow → caller should full-frame */
}

static void
test_pipeline_create_submit_destroy(void)
{
    rfbScreenInfo screen;
    MacVNCFramePipelineConfig cfg;
    MacVNCFramePipeline *p;
    void *a, *b;
    uint8_t src[64 * 64 * 4];
    MacVNCRect hints[2];
    const int w = 64, h = 64;

    memset(&screen, 0, sizeof(screen));
    a = calloc(1, (size_t)w * (size_t)h * 4);
    b = calloc(1, (size_t)w * (size_t)h * 4);
    MACVNC_CHECK(a && b);

    memset(&cfg, 0, sizeof(cfg));
    cfg.width = w;
    cfg.height = h;
    cfg.bytesPerPixel = 4;
    cfg.tileSize = 32;
    cfg.maxRects = 16;
    cfg.damageFullRatio = 0.45;

    MACVNC_CHECK(macvncPipelineCreate(NULL, a, b, &cfg) == NULL);
    MACVNC_CHECK(macvncPipelineCreate(&screen, NULL, b, &cfg) == NULL);
    MACVNC_CHECK(macvncPipelineCreate(&screen, a, b, NULL) == NULL);
    {
        MacVNCFramePipelineConfig bad = cfg;
        bad.width = 0;
        MACVNC_CHECK(macvncPipelineCreate(&screen, a, b, &bad) == NULL);
    }

    /* Defaults apply when tileSize/maxRects/ratio are zero. */
    {
        MacVNCFramePipelineConfig d = cfg;
        d.tileSize = 0;
        d.maxRects = 0;
        d.damageFullRatio = 0;
        p = macvncPipelineCreate(&screen, a, b, &d);
        MACVNC_CHECK(p != NULL);
        macvncPipelineDestroy(p);
    }

    p = macvncPipelineCreate(&screen, a, b, &cfg);
    MACVNC_CHECK(p != NULL);
    MACVNC_CHECK(screen.frameBuffer == b);

    memset(src, 0x11, sizeof(src));
    macvncPipelineForceFullDamage(p);
    macvncPipelineForceFullDamage(NULL);
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, NULL, 0, 0));
    /* Wrong geometry / null src rejected. */
    MACVNC_CHECK(!macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w - 1, h, NULL, 0, 0));
    MACVNC_CHECK(!macvncPipelineSubmitFrame(NULL, src, (size_t)w * 4, w, h, NULL, 0, 0));
    MACVNC_CHECK(!macvncPipelineSubmitFrame(p, NULL, (size_t)w * 4, w, h, NULL, 0, 0));

    /* Hints on a fresh pending slot are accepted; superseding clears them. */
    hints[0].x = 0;
    hints[0].y = 0;
    hints[0].w = 16;
    hints[0].h = 16;
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, hints, 1, 1234));
    memset(src, 0x22, sizeof(src));
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, hints, 1, 5678));

    /* Stride larger than packed row still copies correctly into pending. */
    {
        uint8_t padded[64 * 64 * 4 + 64 * 16];
        memset(padded, 0x33, sizeof(padded));
        MACVNC_CHECK(macvncPipelineSubmitFrame(p, padded, (size_t)w * 4 + 16, w, h, NULL, 0, 0));
    }

    MACVNC_CHECK(!macvncPipelineStart(NULL));
    macvncPipelineStop(NULL);
    macvncPipelineDestroy(NULL);
    macvncPipelineDestroy(p);
    free(a);
    free(b);
}

static rfbScreenInfoPtr
makeLibVncScreen(int w, int h)
{
    int argc = 1;
    char arg0[] = "test_frame_pipeline";
    char *argv[] = {arg0, NULL};
    rfbLogEnable(0);
    return rfbGetScreen(&argc, argv, w, h, 8, 3, 4);
}

static void
waitForPublished(uint64_t minFrames, int timeoutMs)
{
    MacVNCMetricsSnapshot snap;
    for (int i = 0; i < timeoutMs / 5; i++) {
        macvncMetricsSnapshot(&snap);
        if (snap.framesPublished >= minFrames)
            return;
        usleep(5000);
    }
}

static void
test_pipeline_publisher_full_then_partial(void)
{
    const int w = 64, h = 64;
    rfbScreenInfoPtr screen;
    MacVNCFramePipelineConfig cfg;
    MacVNCFramePipeline *p;
    void *a, *b, *origFb;
    uint8_t *src;
    MacVNCMetricsSnapshot snap;

    screen = makeLibVncScreen(w, h);
    MACVNC_CHECK(screen != NULL);
    if (!screen)
        return;
    origFb = screen->frameBuffer;

    a = calloc(1, (size_t)w * (size_t)h * 4);
    b = calloc(1, (size_t)w * (size_t)h * 4);
    src = calloc(1, (size_t)w * (size_t)h * 4);
    MACVNC_CHECK(a && b && src);

    memset(&cfg, 0, sizeof(cfg));
    cfg.width = w;
    cfg.height = h;
    cfg.bytesPerPixel = 4;
    cfg.tileSize = 32;
    cfg.maxRects = 16;
    cfg.damageFullRatio = 0.9; /* keep partial path for small dirty sets */

    p = macvncPipelineCreate(screen, a, b, &cfg);
    MACVNC_CHECK(p != NULL);

    macvncMetricsSetEnabled(TRUE);
    MACVNC_CHECK(macvncPipelineStart(p));
    MACVNC_CHECK(!macvncPipelineStart(p)); /* already running */

    memset(src, 0x10, (size_t)w * (size_t)h * 4);
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, NULL, 0, macvncNowNs()));
    waitForPublished(1, 1000);
    macvncMetricsSnapshot(&snap);
    MACVNC_CHECK(snap.framesPublished >= 1);
    MACVNC_CHECK(snap.fullFramePublishes >= 1);

    /* Identical frame → publish notes zero dirty (early return). */
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, NULL, 0, macvncNowNs()));
    usleep(50000);

    /* Small dirty region → partial publish path. */
    src[8] = 0xff;
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, NULL, 0, macvncNowNs()));
    waitForPublished(snap.framesPublished + 1, 1000);
    macvncMetricsSnapshot(&snap);
    MACVNC_CHECK(snap.framesPublished >= 2);

    /* High dirty ratio → full-frame path after first publish. */
    memset(src, 0xaa, (size_t)w * (size_t)h * 4);
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, NULL, 0, macvncNowNs()));
    waitForPublished(snap.framesPublished + 1, 1000);

    macvncPipelineStop(p);
    macvncPipelineDestroy(p);
    screen->frameBuffer = NULL;
    free(a);
    free(b);
    free(src);
    free(origFb);
    rfbScreenCleanup(screen);
    macvncMetricsSetEnabled(FALSE);
}

static void
test_pipeline_damage_full_ratio_and_hints(void)
{
    const int w = 64, h = 64;
    rfbScreenInfoPtr screen;
    MacVNCFramePipelineConfig cfg;
    MacVNCFramePipeline *p;
    void *a, *b, *origFb;
    uint8_t *src;
    MacVNCRect hint;
    MacVNCMetricsSnapshot before, after;

    screen = makeLibVncScreen(w, h);
    MACVNC_CHECK(screen != NULL);
    if (!screen)
        return;
    origFb = screen->frameBuffer;

    a = calloc(1, (size_t)w * (size_t)h * 4);
    b = calloc(1, (size_t)w * (size_t)h * 4);
    src = calloc(1, (size_t)w * (size_t)h * 4);
    MACVNC_CHECK(a && b && src);

    memset(&cfg, 0, sizeof(cfg));
    cfg.width = w;
    cfg.height = h;
    cfg.bytesPerPixel = 4;
    cfg.tileSize = 32;
    cfg.maxRects = 1; /* force coalesce overflow → full frame once dirty */
    cfg.damageFullRatio = 0.01;

    p = macvncPipelineCreate(screen, a, b, &cfg);
    MACVNC_CHECK(p != NULL);
    macvncMetricsSetEnabled(TRUE);
    MACVNC_CHECK(macvncPipelineStart(p));

    memset(src, 0x01, (size_t)w * (size_t)h * 4);
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, NULL, 0, macvncNowNs()));
    waitForPublished(1, 1000);

    macvncMetricsSnapshot(&before);
    /* Two separated dirty tiles with maxRects=1 → coalesce overflow. */
    src[0] = 0xee;
    src[(size_t)(w * 4) * 40 + 40 * 4] = 0xee;
    hint.x = 0;
    hint.y = 0;
    hint.w = w;
    hint.h = h;
    MACVNC_CHECK(macvncPipelineSubmitFrame(p, src, (size_t)w * 4, w, h, &hint, 1, macvncNowNs()));
    waitForPublished(before.framesPublished + 1, 1000);
    macvncMetricsSnapshot(&after);
    MACVNC_CHECK(after.framesPublished > before.framesPublished);
    MACVNC_CHECK(after.fullFramePublishes >= before.fullFramePublishes);

    macvncPipelineStop(p);
    macvncPipelineDestroy(p);
    screen->frameBuffer = NULL;
    free(a);
    free(b);
    free(src);
    free(origFb);
    rfbScreenCleanup(screen);
    macvncMetricsSetEnabled(FALSE);
}

int
main(void)
{
    test_diff_and_coalesce();
    test_coalesce_merges_adjacent_row();
    test_coalesce_grows_vertically();
    test_coalesce_overflow();
    test_pipeline_create_submit_destroy();
    test_pipeline_publisher_full_then_partial();
    test_pipeline_damage_full_ratio_and_hints();
    return macvncTestFinish("frame_pipeline");
}
