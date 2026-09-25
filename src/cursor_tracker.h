/*
 * Separate cursor shape/position path for LibVNCServer rich cursor updates.
 */
#ifndef MACVNC_CURSOR_TRACKER_H
#define MACVNC_CURSOR_TRACKER_H

#include <CoreGraphics/CoreGraphics.h>
#include <rfb/rfb.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MacVNCCursorTracker MacVNCCursorTracker;

MacVNCCursorTracker *macvncCursorTrackerCreate(rfbScreenInfoPtr screen, CGDirectDisplayID displayID,
                                               double scale);
void macvncCursorTrackerDestroy(MacVNCCursorTracker *t);

/* Poll system cursor shape/visibility; push rich cursor to LibVNC when changed. */
void macvncCursorTrackerPollShape(MacVNCCursorTracker *t);

/*
 * Poll local pointer position for viewers that render the cursor locally.
 * skipLocal: set when the last motion came from a remote PtrAddEvent.
 */
void macvncCursorTrackerPollPosition(MacVNCCursorTracker *t, rfbBool skipLocal);

void macvncCursorTrackerNoteRemotePointer(MacVNCCursorTracker *t);

/* Map framebuffer coordinates to display global coordinates (Retina/scale aware). */
CGPoint macvncCursorMapFramebufferToDisplay(CGDirectDisplayID displayID, double scale, int x,
                                            int y);

#ifdef __cplusplus
}
#endif

#endif /* MACVNC_CURSOR_TRACKER_H */
