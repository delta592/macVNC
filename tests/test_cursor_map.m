#include "cursor_tracker.h"
#include "test_harness.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static rfbScreenInfoPtr
makeLibVncScreen(int w, int h)
{
    int argc = 1;
    char arg0[] = "test_cursor_map";
    char *argv[] = {arg0, NULL};
    rfbLogEnable(0);
    return rfbGetScreen(&argc, argv, w, h, 8, 3, 4);
}

static void
test_map_framebuffer_to_display(void)
{
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);
    CGPoint p;

    p = macvncCursorMapFramebufferToDisplay(display, 1.0, 0, 0);
    MACVNC_CHECK(fabs(p.x - bounds.origin.x) < 0.01);
    MACVNC_CHECK(fabs(p.y - bounds.origin.y) < 0.01);

    p = macvncCursorMapFramebufferToDisplay(display, 1.0, 100, 50);
    MACVNC_CHECK(fabs(p.x - (bounds.origin.x + 100.0)) < 0.01);
    MACVNC_CHECK(fabs(p.y - (bounds.origin.y + 50.0)) < 0.01);

    /* scale 0.5: framebuffer coords are half of display points. */
    p = macvncCursorMapFramebufferToDisplay(display, 0.5, 100, 50);
    MACVNC_CHECK(fabs(p.x - (bounds.origin.x + 200.0)) < 0.01);
    MACVNC_CHECK(fabs(p.y - (bounds.origin.y + 100.0)) < 0.01);

    /* Non-positive scale falls back to 1.0. */
    p = macvncCursorMapFramebufferToDisplay(display, 0.0, 10, 20);
    MACVNC_CHECK(fabs(p.x - (bounds.origin.x + 10.0)) < 0.01);
    MACVNC_CHECK(fabs(p.y - (bounds.origin.y + 20.0)) < 0.01);

    p = macvncCursorMapFramebufferToDisplay(display, -1.0, 3, 4);
    MACVNC_CHECK(fabs(p.x - (bounds.origin.x + 3.0)) < 0.01);
    MACVNC_CHECK(fabs(p.y - (bounds.origin.y + 4.0)) < 0.01);
}

static void
test_tracker_lifecycle(void)
{
    rfbScreenInfo screen;
    MacVNCCursorTracker *t;

    memset(&screen, 0, sizeof(screen));
    screen.width = 320;
    screen.height = 200;
    screen.cursorX = 1;
    screen.cursorY = 2;

    t = macvncCursorTrackerCreate(&screen, CGMainDisplayID(), 0.0); /* scale defaults to 1 */
    MACVNC_CHECK(t != NULL);
    macvncCursorTrackerNoteRemotePointer(NULL);
    macvncCursorTrackerNoteRemotePointer(t);
    /* skipLocal path should be a no-op. */
    macvncCursorTrackerPollPosition(t, TRUE);
    MACVNC_CHECK(screen.cursorX == 1);
    MACVNC_CHECK(screen.cursorY == 2);
    macvncCursorTrackerPollPosition(NULL, FALSE);
    macvncCursorTrackerPollShape(NULL);
    macvncCursorTrackerDestroy(t);
    macvncCursorTrackerDestroy(NULL);
}

static void
test_tracker_poll_shape_and_position(void)
{
    rfbScreenInfoPtr screen;
    MacVNCCursorTracker *t;
    const int w = 640, h = 480;

    screen = makeLibVncScreen(w, h);
    MACVNC_CHECK(screen != NULL);
    if (!screen)
        return;

    t = macvncCursorTrackerCreate(screen, CGMainDisplayID(), 1.0);
    MACVNC_CHECK(t != NULL);

    /* First poll installs a rich cursor; second hits the fingerprint fast path. */
    macvncCursorTrackerPollShape(t);
    macvncCursorTrackerPollShape(t);

    /* Recent remote pointer should suppress local position updates. */
    macvncCursorTrackerNoteRemotePointer(t);
    screen->cursorX = 11;
    screen->cursorY = 22;
    macvncCursorTrackerPollPosition(t, FALSE);
    MACVNC_CHECK(screen->cursorX == 11);
    MACVNC_CHECK(screen->cursorY == 22);

    /* After the 50ms grace window, local mouse mapping may update cursor. */
    usleep(60000);
    macvncCursorTrackerPollPosition(t, FALSE);
    MACVNC_CHECK(screen->cursorX >= 0);
    MACVNC_CHECK(screen->cursorY >= 0);
    MACVNC_CHECK(screen->cursorX < w);
    MACVNC_CHECK(screen->cursorY < h);

    macvncCursorTrackerDestroy(t);
    {
        void *fb = screen->frameBuffer;
        screen->frameBuffer = NULL;
        free(fb);
    }
    rfbScreenCleanup(screen);
}

int
main(void)
{
    test_map_framebuffer_to_display();
    test_tracker_lifecycle();
    test_tracker_poll_shape_and_position();
    return macvncTestFinish("cursor_map");
}
