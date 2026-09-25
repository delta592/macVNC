/*
 * Bounded latest-frame handoff between ScreenCaptureKit and LibVNCServer.
 *
 * Capture publishes into a single pending slot and returns immediately.
 * A publisher thread consumes the latest frame, diffs against the last
 * published framebuffer, then briefly takes client sendMutexes to swap and
 * mark dirty regions.
 */
#ifndef MACVNC_FRAME_PIPELINE_H
#define MACVNC_FRAME_PIPELINE_H

#include <rfb/rfb.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int x;
    int y;
    int w;
    int h;
} MacVNCRect;

typedef struct MacVNCFramePipeline MacVNCFramePipeline;

typedef struct {
    int width;
    int height;
    int bytesPerPixel;
    int tileSize;           /* 32 or 64 recommended */
    int maxRects;           /* coalesce bound; overflow → full frame */
    double damageFullRatio; /* if dirty fraction ≥ this, mark full frame */
} MacVNCFramePipelineConfig;

MacVNCFramePipeline *macvncPipelineCreate(rfbScreenInfoPtr screen, void *frameBufferOne,
                                          void *frameBufferTwo,
                                          const MacVNCFramePipelineConfig *cfg);
void macvncPipelineDestroy(MacVNCFramePipeline *p);

rfbBool macvncPipelineStart(MacVNCFramePipeline *p);
void macvncPipelineStop(MacVNCFramePipeline *p);

/* Capture path: stride-aware copy into the pending slot. Never waits on sendMutex. */
rfbBool macvncPipelineSubmitFrame(MacVNCFramePipeline *p, const uint8_t *src, size_t srcBytesPerRow,
                                  int width, int height, const MacVNCRect *hintRects, int hintCount,
                                  uint64_t captureTimeNs);

void macvncPipelineForceFullDamage(MacVNCFramePipeline *p);

/* Pure helpers exported for unit tests. */
int macvncPipelineDiffTiles(const uint8_t *prev, const uint8_t *next, int width, int height,
                            int bytesPerPixel, int strideBytes, int tileSize, uint8_t *tileMapOut,
                            int tilesX, int tilesY, const MacVNCRect *clip, int clipCount);

int macvncPipelineCoalesceTiles(const uint8_t *tileMap, int tilesX, int tilesY, int tileSize,
                                int fbW, int fbH, MacVNCRect *rectsOut, int maxRects);

#ifdef __cplusplus
}
#endif

#endif /* MACVNC_FRAME_PIPELINE_H */
