#include "frame_pipeline.h"
#include "test_harness.h"

#include <stdlib.h>
#include <string.h>

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
        MacVNCRect clip = { .x = 0, .y = 0, .w = 16, .h = 16 };
        memset(tileMap, 0, (size_t)tilesX * (size_t)tilesY);
        /* Change far away — outside clip — should report 0 when clipped. */
        memset(next, 0, (size_t)stride * (size_t)h);
        memset(next + 40 * stride + 100 * bpp, 0xaa, 4);
        dirty = macvncPipelineDiffTiles(prev, next, w, h, bpp, stride, tile, tileMap, tilesX, tilesY,
                                        &clip, 1);
        MACVNC_CHECK(dirty == 0);
    }

    free(prev);
    free(next);
    free(tileMap);
}

static void
test_coalesce_overflow(void)
{
    const int tilesX = 4, tilesY = 4, tile = 32;
    uint8_t tileMap[16];
    MacVNCRect rects[2];
    int n;

    memset(tileMap, 1, sizeof(tileMap)); /* checker not needed — all dirty, non-mergeable if we
                                           * break adjacency: use isolated tiles */
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

int
main(void)
{
    test_diff_and_coalesce();
    test_coalesce_overflow();
    return macvncTestFinish("frame_pipeline");
}
