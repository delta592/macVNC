#include "frame_pipeline.h"
#include "macvnc_metrics.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define MACVNC_PIPELINE_MAX_CLIENTS 256
#define MACVNC_PIPELINE_MAX_HINTS 64

struct MacVNCFramePipeline {
    rfbScreenInfoPtr screen;
    void *bufA;
    void *bufB;
    void *backBuffer; /* next publish target; front is screen->frameBuffer */

    int width;
    int height;
    int bpp;
    int stride; /* packed destination stride in bytes */
    int tileSize;
    int tilesX;
    int tilesY;
    int maxRects;
    double damageFullRatio;

    uint8_t *pending; /* owned staging buffer for latest capture */
    uint8_t *tileMap;
    MacVNCRect hintRects[MACVNC_PIPELINE_MAX_HINTS];
    int hintCount;
    rfbBool pendingValid;
    rfbBool pendingHadDrop; /* at least one frame superseded since last take */
    rfbBool forceFull;
    rfbBool havePublished;
    uint64_t pendingCaptureNs;
    uint64_t generation;

    pthread_mutex_t lock;
    pthread_cond_t cond;
    pthread_t thread;
    rfbBool running;
    rfbBool stopRequested;
};

static void
copyRows(uint8_t *dst, int dstStride, const uint8_t *src, size_t srcStride, int width, int height,
         int bpp)
{
    int rowBytes = width * bpp;
    for (int y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * (size_t)dstStride, src + (size_t)y * srcStride, (size_t)rowBytes);
    }
}

int
macvncPipelineDiffTiles(const uint8_t *prev, const uint8_t *next, int width, int height,
                        int bytesPerPixel, int strideBytes, int tileSize, uint8_t *tileMapOut,
                        int tilesX, int tilesY, const MacVNCRect *clip, int clipCount)
{
    int dirty = 0;
    memset(tileMapOut, 0, (size_t)tilesX * (size_t)tilesY);

    if (clip && clipCount > 0) {
        for (int i = 0; i < clipCount; i++) {
            int x0 = clip[i].x;
            int y0 = clip[i].y;
            int x1 = clip[i].x + clip[i].w;
            int y1 = clip[i].y + clip[i].h;
            if (x0 < 0)
                x0 = 0;
            if (y0 < 0)
                y0 = 0;
            if (x1 > width)
                x1 = width;
            if (y1 > height)
                y1 = height;
            if (x0 >= x1 || y0 >= y1)
                continue;
            int tx0 = x0 / tileSize;
            int ty0 = y0 / tileSize;
            int tx1 = (x1 - 1) / tileSize;
            int ty1 = (y1 - 1) / tileSize;
            for (int ty = ty0; ty <= ty1; ty++) {
                for (int tx = tx0; tx <= tx1; tx++) {
                    tileMapOut[ty * tilesX + tx] = 1;
                }
            }
        }
    } else {
        memset(tileMapOut, 1, (size_t)tilesX * (size_t)tilesY);
    }

    for (int ty = 0; ty < tilesY; ty++) {
        for (int tx = 0; tx < tilesX; tx++) {
            int idx = ty * tilesX + tx;
            if (!tileMapOut[idx])
                continue;
            int x0 = tx * tileSize;
            int y0 = ty * tileSize;
            int tw = tileSize;
            int th = tileSize;
            if (x0 + tw > width)
                tw = width - x0;
            if (y0 + th > height)
                th = height - y0;
            rfbBool changed = FALSE;
            for (int y = 0; y < th && !changed; y++) {
                const uint8_t *a = prev + (size_t)(y0 + y) * (size_t)strideBytes +
                                   (size_t)x0 * (size_t)bytesPerPixel;
                const uint8_t *b = next + (size_t)(y0 + y) * (size_t)strideBytes +
                                   (size_t)x0 * (size_t)bytesPerPixel;
                if (memcmp(a, b, (size_t)tw * (size_t)bytesPerPixel) != 0)
                    changed = TRUE;
            }
            if (changed) {
                dirty++;
            } else {
                tileMapOut[idx] = 0;
            }
        }
    }
    return dirty;
}

int
macvncPipelineCoalesceTiles(const uint8_t *tileMap, int tilesX, int tilesY, int tileSize, int fbW,
                            int fbH, MacVNCRect *rectsOut, int maxRects)
{
    int n = 0;
    uint8_t *seen = calloc((size_t)tilesX * (size_t)tilesY, 1);
    if (!seen)
        return -1;

    for (int ty = 0; ty < tilesY; ty++) {
        for (int tx = 0; tx < tilesX; tx++) {
            int idx = ty * tilesX + tx;
            if (!tileMap[idx] || seen[idx])
                continue;
            int tx1 = tx;
            while (tx1 + 1 < tilesX && tileMap[ty * tilesX + (tx1 + 1)] &&
                   !seen[ty * tilesX + (tx1 + 1)])
                tx1++;
            int ty1 = ty;
            rfbBool grew = TRUE;
            while (grew && ty1 + 1 < tilesY) {
                grew = TRUE;
                for (int x = tx; x <= tx1; x++) {
                    if (!tileMap[(ty1 + 1) * tilesX + x] || seen[(ty1 + 1) * tilesX + x]) {
                        grew = FALSE;
                        break;
                    }
                }
                if (grew)
                    ty1++;
            }
            for (int y = ty; y <= ty1; y++)
                for (int x = tx; x <= tx1; x++)
                    seen[y * tilesX + x] = 1;

            if (n >= maxRects) {
                free(seen);
                return -1; /* signal overflow → caller uses full frame */
            }
            int x0 = tx * tileSize;
            int y0 = ty * tileSize;
            int x1 = (tx1 + 1) * tileSize;
            int y1 = (ty1 + 1) * tileSize;
            if (x1 > fbW)
                x1 = fbW;
            if (y1 > fbH)
                y1 = fbH;
            rectsOut[n].x = x0;
            rectsOut[n].y = y0;
            rectsOut[n].w = x1 - x0;
            rectsOut[n].h = y1 - y0;
            n++;
            tx = tx1;
        }
    }
    free(seen);
    return n;
}

MacVNCFramePipeline *
macvncPipelineCreate(rfbScreenInfoPtr screen, void *frameBufferOne, void *frameBufferTwo,
                     const MacVNCFramePipelineConfig *cfg)
{
    MacVNCFramePipeline *p;
    if (!screen || !frameBufferOne || !frameBufferTwo || !cfg || cfg->width <= 0 ||
        cfg->height <= 0 || cfg->bytesPerPixel <= 0)
        return NULL;

    p = calloc(1, sizeof(*p));
    if (!p)
        return NULL;

    p->screen = screen;
    p->bufA = frameBufferOne;
    p->bufB = frameBufferTwo;
    p->backBuffer = frameBufferOne;
    screen->frameBuffer = frameBufferTwo;

    p->width = cfg->width;
    p->height = cfg->height;
    p->bpp = cfg->bytesPerPixel;
    p->stride = cfg->width * cfg->bytesPerPixel;
    p->tileSize = cfg->tileSize > 0 ? cfg->tileSize : 64;
    p->tilesX = (cfg->width + p->tileSize - 1) / p->tileSize;
    p->tilesY = (cfg->height + p->tileSize - 1) / p->tileSize;
    p->maxRects = cfg->maxRects > 0 ? cfg->maxRects : 64;
    p->damageFullRatio = cfg->damageFullRatio > 0 ? cfg->damageFullRatio : 0.45;

    p->pending = malloc((size_t)p->stride * (size_t)p->height);
    p->tileMap = malloc((size_t)p->tilesX * (size_t)p->tilesY);
    if (!p->pending || !p->tileMap) {
        macvncPipelineDestroy(p);
        return NULL;
    }

    pthread_mutex_init(&p->lock, NULL);
    pthread_cond_init(&p->cond, NULL);
    p->forceFull = TRUE;
    return p;
}

void
macvncPipelineDestroy(MacVNCFramePipeline *p)
{
    if (!p)
        return;
    macvncPipelineStop(p);
    free(p->pending);
    free(p->tileMap);
    pthread_mutex_destroy(&p->lock);
    pthread_cond_destroy(&p->cond);
    free(p);
}

void
macvncPipelineForceFullDamage(MacVNCFramePipeline *p)
{
    if (!p)
        return;
    pthread_mutex_lock(&p->lock);
    p->forceFull = TRUE;
    pthread_mutex_unlock(&p->lock);
}

rfbBool
macvncPipelineSubmitFrame(MacVNCFramePipeline *p, const uint8_t *src, size_t srcBytesPerRow,
                          int width, int height, const MacVNCRect *hintRects, int hintCount,
                          uint64_t captureTimeNs)
{
    uint64_t waitStart, waitNs;
    rfbBool superseded;

    if (!p || !src || width != p->width || height != p->height || srcBytesPerRow == 0)
        return FALSE;

    waitStart = macvncNowNs();
    pthread_mutex_lock(&p->lock);
    waitNs = macvncNowNs() - waitStart;

    superseded = p->pendingValid;
    copyRows(p->pending, p->stride, src, srcBytesPerRow, width, height, p->bpp);

    p->hintCount = 0;
    if (hintRects && hintCount > 0 && !superseded) {
        int n = hintCount;
        if (n > MACVNC_PIPELINE_MAX_HINTS)
            n = MACVNC_PIPELINE_MAX_HINTS;
        memcpy(p->hintRects, hintRects, (size_t)n * sizeof(MacVNCRect));
        p->hintCount = n;
    } else {
        /* Dropped frame(s): ignore stale capture hints; publisher will full-compare. */
        p->hintCount = 0;
        if (superseded)
            p->pendingHadDrop = TRUE;
    }

    p->pendingValid = TRUE;
    p->pendingCaptureNs = captureTimeNs ? captureTimeNs : macvncNowNs();
    p->generation++;
    pthread_cond_signal(&p->cond);
    pthread_mutex_unlock(&p->lock);

    macvncMetricsNoteSubmit(waitNs, superseded, superseded ? 1 : 1);
    return TRUE;
}

static void
lockClients(rfbScreenInfoPtr screen, rfbClientPtr *clients, int *countOut)
{
    rfbClientIteratorPtr it;
    rfbClientPtr cl;
    int n = 0;

    it = rfbGetClientIterator(screen);
    while ((cl = rfbClientIteratorNext(it)) != NULL && n < MACVNC_PIPELINE_MAX_CLIENTS) {
        clients[n++] = cl;
        /* Keep the ref from the iterator by bumping again before next advances. */
        rfbIncrClientRef(cl);
        LOCK(cl->sendMutex);
    }
    rfbReleaseClientIterator(it);
    *countOut = n;
}

static void
unlockClients(rfbClientPtr *clients, int count)
{
    for (int i = 0; i < count; i++) {
        UNLOCK(clients[i]->sendMutex);
        rfbDecrClientRef(clients[i]);
    }
}

static void
publishOne(MacVNCFramePipeline *p)
{
    uint8_t *front;
    uint8_t *pendingCopy = NULL;
    MacVNCRect hints[MACVNC_PIPELINE_MAX_HINTS];
    MacVNCRect rects[128];
    int hintCount = 0;
    int rectCount = 0;
    rfbBool forceFull;
    rfbBool hadDrop;
    rfbBool fullFrame;
    uint64_t captureNs;
    uint64_t copyStart, copyNs, lockStart, lockNs;
    uint64_t dirtyTiles = 0, dirtyPixels = 0, bytesCopied = 0;
    rfbClientPtr clients[MACVNC_PIPELINE_MAX_CLIENTS];
    int clientCount = 0;
    size_t frameBytes;

    frameBytes = (size_t)p->stride * (size_t)p->height;
    pendingCopy = malloc(frameBytes);
    if (!pendingCopy)
        return;

    pthread_mutex_lock(&p->lock);
    while (p->running && !p->pendingValid && !p->stopRequested)
        pthread_cond_wait(&p->cond, &p->lock);

    if (p->stopRequested || !p->pendingValid) {
        pthread_mutex_unlock(&p->lock);
        free(pendingCopy);
        return;
    }

    memcpy(pendingCopy, p->pending, frameBytes);
    hintCount = p->hintCount;
    if (hintCount > 0)
        memcpy(hints, p->hintRects, (size_t)hintCount * sizeof(MacVNCRect));
    forceFull = p->forceFull || !p->havePublished;
    hadDrop = p->pendingHadDrop;
    captureNs = p->pendingCaptureNs;
    p->pendingValid = FALSE;
    p->hintCount = 0;
    p->pendingHadDrop = FALSE;
    p->forceFull = FALSE;
    pthread_mutex_unlock(&p->lock);

    /* Re-check for a newer pending frame after we release the lock so long
     * encode waits do not publish a stale candidate when a fresher one exists. */
    pthread_mutex_lock(&p->lock);
    if (p->pendingValid) {
        memcpy(pendingCopy, p->pending, frameBytes);
        hintCount = p->hintCount;
        if (hintCount > 0)
            memcpy(hints, p->hintRects, (size_t)hintCount * sizeof(MacVNCRect));
        else
            hintCount = 0;
        hadDrop = hadDrop || p->pendingHadDrop;
        captureNs = p->pendingCaptureNs;
        p->pendingValid = FALSE;
        p->hintCount = 0;
        p->pendingHadDrop = FALSE;
    }
    pthread_mutex_unlock(&p->lock);

    front = (uint8_t *)p->screen->frameBuffer;
    copyStart = macvncNowNs();

    if (forceFull || hadDrop)
        hintCount = 0;

    if (forceFull) {
        fullFrame = TRUE;
        memcpy(p->backBuffer, pendingCopy, frameBytes);
        bytesCopied = frameBytes;
        dirtyTiles = (uint64_t)p->tilesX * (uint64_t)p->tilesY;
        dirtyPixels = (uint64_t)p->width * (uint64_t)p->height;
        rects[0].x = 0;
        rects[0].y = 0;
        rects[0].w = p->width;
        rects[0].h = p->height;
        rectCount = 1;
    } else {
        dirtyTiles = (uint64_t)macvncPipelineDiffTiles(
            front, pendingCopy, p->width, p->height, p->bpp, p->stride, p->tileSize, p->tileMap,
            p->tilesX, p->tilesY, hintCount > 0 ? hints : NULL, hintCount);

        if (dirtyTiles == 0) {
            copyNs = macvncNowNs() - copyStart;
            macvncMetricsNotePublish(macvncNowNs() - captureNs, 0, copyNs, 0, 0, 0, FALSE);
            free(pendingCopy);
            return;
        }

        double ratio =
            (double)dirtyTiles / ((double)p->tilesX * (double)p->tilesY);
        int coalesced = macvncPipelineCoalesceTiles(p->tileMap, p->tilesX, p->tilesY, p->tileSize,
                                                    p->width, p->height, rects, p->maxRects);
        if (coalesced < 0 || ratio >= p->damageFullRatio) {
            fullFrame = TRUE;
            memcpy(p->backBuffer, pendingCopy, frameBytes);
            bytesCopied = frameBytes;
            dirtyPixels = (uint64_t)p->width * (uint64_t)p->height;
            rects[0].x = 0;
            rects[0].y = 0;
            rects[0].w = p->width;
            rects[0].h = p->height;
            rectCount = 1;
        } else {
            fullFrame = FALSE;
            rectCount = coalesced;
            dirtyPixels = 0;
            for (int i = 0; i < rectCount; i++) {
                int rowBytes = rects[i].w * p->bpp;
                for (int y = 0; y < rects[i].h; y++) {
                    uint8_t *d = (uint8_t *)p->backBuffer +
                                 (size_t)(rects[i].y + y) * (size_t)p->stride +
                                 (size_t)rects[i].x * (size_t)p->bpp;
                    const uint8_t *s = pendingCopy + (size_t)(rects[i].y + y) * (size_t)p->stride +
                                       (size_t)rects[i].x * (size_t)p->bpp;
                    memcpy(d, s, (size_t)rowBytes);
                }
                bytesCopied += (uint64_t)rowBytes * (uint64_t)rects[i].h;
                dirtyPixels += (uint64_t)rects[i].w * (uint64_t)rects[i].h;
            }
            /* Unchanged pixels must still match front so the new front is complete. */
            for (int ty = 0; ty < p->tilesY; ty++) {
                for (int tx = 0; tx < p->tilesX; tx++) {
                    if (p->tileMap[ty * p->tilesX + tx])
                        continue;
                    int x0 = tx * p->tileSize;
                    int y0 = ty * p->tileSize;
                    int tw = p->tileSize;
                    int th = p->tileSize;
                    if (x0 + tw > p->width)
                        tw = p->width - x0;
                    if (y0 + th > p->height)
                        th = p->height - y0;
                    for (int y = 0; y < th; y++) {
                        memcpy((uint8_t *)p->backBuffer +
                                   (size_t)(y0 + y) * (size_t)p->stride +
                                   (size_t)x0 * (size_t)p->bpp,
                               front + (size_t)(y0 + y) * (size_t)p->stride +
                                   (size_t)x0 * (size_t)p->bpp,
                               (size_t)tw * (size_t)p->bpp);
                    }
                }
            }
        }
    }
    copyNs = macvncNowNs() - copyStart;

    lockStart = macvncNowNs();
    lockClients(p->screen, clients, &clientCount);
    lockNs = macvncNowNs() - lockStart;

    if (p->backBuffer == p->bufA) {
        p->backBuffer = p->bufB;
        p->screen->frameBuffer = p->bufA;
    } else {
        p->backBuffer = p->bufA;
        p->screen->frameBuffer = p->bufB;
    }

    for (int i = 0; i < rectCount; i++) {
        rfbMarkRectAsModified(p->screen, rects[i].x, rects[i].y, rects[i].x + rects[i].w,
                              rects[i].y + rects[i].h);
    }

    unlockClients(clients, clientCount);
    p->havePublished = TRUE;

    macvncMetricsNotePublish(macvncNowNs() - captureNs, lockNs, copyNs, dirtyTiles, dirtyPixels,
                             bytesCopied, fullFrame);
    free(pendingCopy);
}

static void *
publisherMain(void *arg)
{
    MacVNCFramePipeline *p = arg;
    while (p->running) {
        pthread_mutex_lock(&p->lock);
        while (p->running && !p->pendingValid && !p->stopRequested)
            pthread_cond_wait(&p->cond, &p->lock);
        if (p->stopRequested) {
            pthread_mutex_unlock(&p->lock);
            break;
        }
        pthread_mutex_unlock(&p->lock);
        publishOne(p);
    }
    return NULL;
}

rfbBool
macvncPipelineStart(MacVNCFramePipeline *p)
{
    if (!p || p->running)
        return FALSE;
    p->stopRequested = FALSE;
    p->running = TRUE;
    if (pthread_create(&p->thread, NULL, publisherMain, p) != 0) {
        p->running = FALSE;
        return FALSE;
    }
    return TRUE;
}

void
macvncPipelineStop(MacVNCFramePipeline *p)
{
    if (!p || !p->running)
        return;
    pthread_mutex_lock(&p->lock);
    p->stopRequested = TRUE;
    p->running = FALSE;
    pthread_cond_signal(&p->cond);
    pthread_mutex_unlock(&p->lock);
    pthread_join(p->thread, NULL);
}
