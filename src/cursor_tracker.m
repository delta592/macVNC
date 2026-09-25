#import "cursor_tracker.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include "macvnc_metrics.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct MacVNCCursorTracker {
    rfbScreenInfoPtr screen;
    CGDirectDisplayID displayID;
    double scale;
    pthread_mutex_t lock;
    uint64_t lastRemotePointerNs;
    uint64_t shapeFingerprint;
    rfbBool haveShape;
    rfbBool lastHidden;
};

CGPoint
macvncCursorMapFramebufferToDisplay(CGDirectDisplayID displayID, double scale, int x, int y)
{
    CGRect bounds = CGDisplayBounds(displayID);
    double s = (scale > 0.0) ? scale : 1.0;
    CGPoint p;
    p.x = bounds.origin.x + ((CGFloat)x / s);
    p.y = bounds.origin.y + ((CGFloat)y / s);
    return p;
}

MacVNCCursorTracker *
macvncCursorTrackerCreate(rfbScreenInfoPtr screen, CGDirectDisplayID displayID, double scale)
{
    MacVNCCursorTracker *t = calloc(1, sizeof(*t));
    if (!t)
        return NULL;
    t->screen = screen;
    t->displayID = displayID;
    t->scale = scale > 0.0 ? scale : 1.0;
    pthread_mutex_init(&t->lock, NULL);
    return t;
}

void
macvncCursorTrackerDestroy(MacVNCCursorTracker *t)
{
    if (!t)
        return;
    pthread_mutex_destroy(&t->lock);
    free(t);
}

void
macvncCursorTrackerNoteRemotePointer(MacVNCCursorTracker *t)
{
    if (!t)
        return;
    pthread_mutex_lock(&t->lock);
    t->lastRemotePointerNs = macvncNowNs();
    pthread_mutex_unlock(&t->lock);
}

static uint64_t
fingerprintBitmap(const unsigned char *rgba, int w, int h, int hotX, int hotY)
{
    uint64_t hsh = 14695981039346656037ULL;
    size_t n = (size_t)w * (size_t)h * 4;
    hsh ^= (uint64_t)(uint32_t)w;
    hsh *= 1099511628211ULL;
    hsh ^= (uint64_t)(uint32_t)h;
    hsh *= 1099511628211ULL;
    hsh ^= (uint64_t)(uint32_t)hotX;
    hsh *= 1099511628211ULL;
    hsh ^= (uint64_t)(uint32_t)hotY;
    hsh *= 1099511628211ULL;
    for (size_t i = 0; i < n; i++) {
        hsh ^= rgba[i];
        hsh *= 1099511628211ULL;
    }
    return hsh;
}

static rfbCursorPtr
makeRichCursorFromNSImage(NSImage *image, NSPoint hotSpot, uint64_t *fpOut)
{
    NSBitmapImageRep *rep;
    NSSize size;
    int w, h, rowBytes;
    unsigned char *bgra;
    rfbCursorPtr cursor;
    NSRect rect;
    int hotX, hotY;

    if (!image)
        return NULL;

    size = image.size;
    if (size.width < 1 || size.height < 1)
        return NULL;

    w = (int)size.width;
    h = (int)size.height;
    rect = NSMakeRect(0, 0, w, h);
    hotX = (int)hotSpot.x;
    hotY = (int)hotSpot.y;
    if (hotX < 0)
        hotX = 0;
    if (hotY < 0)
        hotY = 0;
    if (hotX >= w)
        hotX = w - 1;
    if (hotY >= h)
        hotY = h - 1;

    rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                  pixelsWide:w
                                                  pixelsHigh:h
                                               bitsPerSample:8
                                             samplesPerPixel:4
                                                    hasAlpha:YES
                                                    isPlanar:NO
                                              colorSpaceName:NSCalibratedRGBColorSpace
                                                 bytesPerRow:w * 4
                                                bitsPerPixel:32];
    if (!rep)
        return NULL;

    {
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];
        [[NSColor clearColor] set];
        NSRectFill(rect);
        [image drawInRect:rect
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
    }

    rowBytes = (int)rep.bytesPerRow;
    bgra = (unsigned char *)malloc((size_t)w * (size_t)h * 4);
    if (!bgra) {
        [rep release];
        return NULL;
    }

    {
        int maskRowBytes = (w + 7) / 8;
        unsigned char *mask = (unsigned char *)calloc((size_t)maskRowBytes, (size_t)h);
        if (!mask) {
            free(bgra);
            [rep release];
            return NULL;
        }

        for (int y = 0; y < h; y++) {
            const unsigned char *src = [rep bitmapData] + (size_t)y * (size_t)rowBytes;
            unsigned char *dst = bgra + (size_t)y * (size_t)w * 4;
            unsigned char *mrow = mask + (size_t)y * (size_t)maskRowBytes;
            for (int x = 0; x < w; x++) {
                unsigned char r = src[x * 4 + 0];
                unsigned char g = src[x * 4 + 1];
                unsigned char b = src[x * 4 + 2];
                unsigned char a = src[x * 4 + 3];
                dst[x * 4 + 0] = b;
                dst[x * 4 + 1] = g;
                dst[x * 4 + 2] = r;
                dst[x * 4 + 3] = a;
                /*
                 * LibVNC's rfbSendCursorShape always reads pCursor->mask
                 * (even for RichCursor). Bit set = opaque.
                 */
                if (a > 0)
                    mrow[x / 8] |= (unsigned char)(0x80 >> (x % 8));
            }
        }
        [rep release];

        if (fpOut)
            *fpOut = fingerprintBitmap(bgra, w, h, hotX, hotY);

        cursor = (rfbCursorPtr)calloc(1, sizeof(rfbCursor));
        if (!cursor) {
            free(bgra);
            free(mask);
            return NULL;
        }
        cursor->width = (unsigned short)w;
        cursor->height = (unsigned short)h;
        cursor->xhot = (unsigned short)hotX;
        cursor->yhot = (unsigned short)hotY;
        cursor->richSource = bgra;
        cursor->cleanupRichSource = TRUE;
        cursor->mask = mask;
        cursor->cleanupMask = TRUE;
        cursor->cleanup = TRUE;
        cursor->alphaPreMultiplied = FALSE;
        return cursor;
    }
}

void
macvncCursorTrackerPollShape(MacVNCCursorTracker *t)
{
    if (!t || !t->screen)
        return;

    @autoreleasepool {
        NSCursor *sys = [NSCursor currentSystemCursor];
        NSImage *image;
        NSPoint hot;
        rfbCursorPtr cursor;
        uint64_t fp = 0;

        if (!sys)
            sys = [NSCursor arrowCursor];
        image = sys.image;
        hot = sys.hotSpot;

        if (!image) {
            pthread_mutex_lock(&t->lock);
            if (!t->lastHidden) {
                t->lastHidden = TRUE;
                t->haveShape = FALSE;
                pthread_mutex_unlock(&t->lock);
                rfbSetCursor(t->screen, NULL);
            } else {
                pthread_mutex_unlock(&t->lock);
            }
            return;
        }

        cursor = makeRichCursorFromNSImage(image, hot, &fp);
        if (!cursor)
            return;

        pthread_mutex_lock(&t->lock);
        if (t->haveShape && !t->lastHidden && t->shapeFingerprint == fp) {
            pthread_mutex_unlock(&t->lock);
            rfbFreeCursor(cursor);
            return;
        }
        t->shapeFingerprint = fp;
        t->haveShape = TRUE;
        t->lastHidden = FALSE;
        pthread_mutex_unlock(&t->lock);

        rfbSetCursor(t->screen, cursor);
    }
}

static NSScreen *
screenForDisplay(CGDirectDisplayID displayID)
{
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
        if (num && (CGDirectDisplayID)num.unsignedIntValue == displayID)
            return screen;
    }
    return nil;
}

void
macvncCursorTrackerPollPosition(MacVNCCursorTracker *t, rfbBool skipLocal)
{
    uint64_t now, lastRemote;
    double s;
    int x, y;

    if (!t || !t->screen || skipLocal)
        return;

    pthread_mutex_lock(&t->lock);
    lastRemote = t->lastRemotePointerNs;
    pthread_mutex_unlock(&t->lock);

    now = macvncNowNs();
    if (lastRemote && (now - lastRemote) < 50000000ULL)
        return;

    @autoreleasepool {
        NSPoint p = [NSEvent mouseLocation];
        NSScreen *nsScreen = screenForDisplay(t->displayID);
        if (!nsScreen)
            return;

        NSRect f = nsScreen.frame;
        CGFloat cocoaYFromTop = (f.origin.y + f.size.height) - p.y;
        s = t->scale > 0.0 ? t->scale : 1.0;
        x = (int)((p.x - f.origin.x) * s);
        y = (int)(cocoaYFromTop * s);

        if (x < 0)
            x = 0;
        if (y < 0)
            y = 0;
        if (x >= t->screen->width)
            x = t->screen->width - 1;
        if (y >= t->screen->height)
            y = t->screen->height - 1;

        if (x != t->screen->cursorX || y != t->screen->cursorY) {
            t->screen->cursorX = x;
            t->screen->cursorY = y;
        }
    }
}
