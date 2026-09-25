//
// XCTest entry points for the same logic covered by CTest.
// Build with: cmake -G Xcode -DMACVNC_BUILD_XCTEST=ON ...
// Run with:   xcodebuild test -scheme macVNC -destination 'platform=macOS'
//
// OCMock is reserved for future ScreenCapturer / AppKit isolation tests.
//

#import <XCTest/XCTest.h>

#include "cert_manager.h"
#include "cursor_tracker.h"
#include "frame_pipeline.h"
#include "macvnc_metrics.h"
#include "vencrypt.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

@interface CertManagerTests : XCTestCase
@end

@implementation CertManagerTests {
    char _home[512];
}

- (void)setUp
{
    [super setUp];
    char tmpl[] = "/tmp/macvnc-xctest-home.XXXXXX";
    char *dir = mkdtemp(tmpl);
    XCTAssertNotEqual(dir, NULL);
    snprintf(_home, sizeof(_home), "%s", dir);
    setenv("HOME", _home, 1);
}

- (void)tearDown
{
    char cmd[640];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", _home);
    system(cmd);
    [super tearDown];
}

- (void)testCertPathsUseDotMacvnc
{
    char cert[512], key[512], expectCert[512], expectKey[512];
    XCTAssertTrue(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    snprintf(expectCert, sizeof(expectCert), "%s/.macvnc/cert.pem", _home);
    snprintf(expectKey, sizeof(expectKey), "%s/.macvnc/key.pem", _home);
    XCTAssertEqualObjects(@(cert), @(expectCert));
    XCTAssertEqualObjects(@(key), @(expectKey));
}

- (void)testCertEnsureWritesSecureModes
{
    char cert[512], key[512];
    struct stat st;
    XCTAssertTrue(macvncCertEnsure(FALSE));
    XCTAssertTrue(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    XCTAssertEqual(stat(key, &st), 0);
    XCTAssertEqual(st.st_mode & 0777, 0600);
    XCTAssertEqual(stat(cert, &st), 0);
    XCTAssertEqual(st.st_mode & 0777, 0644);
    XCTAssertEqual(st.st_mode & 0002, 0); /* not world-writable */
}

@end

@interface SecurityModeTests : XCTestCase
@end

@implementation SecurityModeTests

- (void)testModeNameStrings
{
    XCTAssertTrue(strstr(macvncSecurityModeName(MACVNC_SECURITY_VENCRYPT_X509), "VeNCrypt") !=
                  NULL);
    XCTAssertTrue(strstr(macvncSecurityModeName(MACVNC_SECURITY_ANONTLS), "AnonTLS") != NULL);
    XCTAssertTrue(strstr(macvncSecurityModeName(MACVNC_SECURITY_PLAIN), "UNENCRYPTED") != NULL);
    XCTAssertEqualObjects(@(macvncSecurityModeName((MacVNCSecurityMode)99)), @"unknown");
}

@end

@interface FramePipelineTests : XCTestCase
@end

@implementation FramePipelineTests

- (void)testDiffAndCoalesceSingleTile
{
    const int w = 64, h = 64, bpp = 4, tile = 32;
    const int stride = w * bpp;
    const int tilesX = 2, tilesY = 2;
    uint8_t *prev = calloc(1, (size_t)stride * (size_t)h);
    uint8_t *next = calloc(1, (size_t)stride * (size_t)h);
    uint8_t tileMap[4];
    MacVNCRect rects[4];
    int dirty, n;

    XCTAssertNotEqual(prev, NULL);
    XCTAssertNotEqual(next, NULL);
    memset(next + 8, 0xff, 4);
    dirty = macvncPipelineDiffTiles(prev, next, w, h, bpp, stride, tile, tileMap, tilesX, tilesY,
                                    NULL, 0);
    XCTAssertEqual(dirty, 1);
    n = macvncPipelineCoalesceTiles(tileMap, tilesX, tilesY, tile, w, h, rects, 4);
    XCTAssertEqual(n, 1);
    XCTAssertEqual(rects[0].w, tile);
    XCTAssertEqual(rects[0].h, tile);
    free(prev);
    free(next);
}

- (void)testCoalesceVerticalBlockAndOverflow
{
    uint8_t tileMap[9] = {1, 1, 0, 1, 1, 0, 0, 0, 0};
    MacVNCRect rects[4];
    int n = macvncPipelineCoalesceTiles(tileMap, 3, 3, 32, 96, 96, rects, 4);
    XCTAssertEqual(n, 1);
    XCTAssertEqual(rects[0].w, 64);
    XCTAssertEqual(rects[0].h, 64);

    uint8_t sparse[16] = {1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1};
    XCTAssertLessThan(macvncPipelineCoalesceTiles(sparse, 4, 4, 32, 128, 128, rects, 2), 0);
}

- (void)testPipelineCreateSubmitDefaults
{
    rfbScreenInfo screen;
    MacVNCFramePipelineConfig cfg;
    void *a = calloc(1, 64 * 64 * 4);
    void *b = calloc(1, 64 * 64 * 4);
    uint8_t src[64 * 64 * 4];
    MacVNCFramePipeline *p;

    memset(&screen, 0, sizeof(screen));
    memset(&cfg, 0, sizeof(cfg));
    cfg.width = 64;
    cfg.height = 64;
    cfg.bytesPerPixel = 4;
    XCTAssertNotEqual(a, NULL);
    XCTAssertNotEqual(b, NULL);
    XCTAssertEqual(macvncPipelineCreate(NULL, a, b, &cfg), NULL);
    p = macvncPipelineCreate(&screen, a, b, &cfg);
    XCTAssertNotEqual(p, NULL);
    memset(src, 0x44, sizeof(src));
    XCTAssertTrue(macvncPipelineSubmitFrame(p, src, 64 * 4, 64, 64, NULL, 0, 0));
    XCTAssertFalse(macvncPipelineSubmitFrame(p, src, 64 * 4, 32, 64, NULL, 0, 0));
    macvncPipelineDestroy(p);
    free(a);
    free(b);
}

@end

@interface MetricsTests : XCTestCase
@end

@implementation MetricsTests

- (void)testSubmitPublishCounters
{
    MacVNCMetricsSnapshot snap;
    macvncMetricsSetEnabled(TRUE);
    macvncMetricsNoteSubmit(5, TRUE, 2);
    macvncMetricsNotePublish(100, 1, 2, 3, 4, 5, TRUE);
    macvncMetricsSnapshot(&snap);
    XCTAssertEqual(snap.framesSubmitted, 1ULL);
    XCTAssertEqual(snap.framesSuperseded, 1ULL);
    XCTAssertEqual(snap.framesPublished, 1ULL);
    XCTAssertEqual(snap.fullFramePublishes, 1ULL);
    XCTAssertEqual(snap.pendingPeak, 2ULL);
    macvncMetricsSetEnabled(FALSE);
}

@end

@interface CursorMapTests : XCTestCase
@end

@implementation CursorMapTests

- (void)testFramebufferToDisplayScale
{
    CGDirectDisplayID display = CGMainDisplayID();
    CGRect bounds = CGDisplayBounds(display);
    CGPoint p = macvncCursorMapFramebufferToDisplay(display, 0.5, 20, 10);
    XCTAssertEqualWithAccuracy(p.x, bounds.origin.x + 40.0, 0.01);
    XCTAssertEqualWithAccuracy(p.y, bounds.origin.y + 20.0, 0.01);
}

- (void)testTrackerCreateDestroy
{
    rfbScreenInfo screen;
    memset(&screen, 0, sizeof(screen));
    screen.width = 100;
    screen.height = 100;
    MacVNCCursorTracker *t = macvncCursorTrackerCreate(&screen, CGMainDisplayID(), 0.0);
    XCTAssertNotEqual(t, NULL);
    macvncCursorTrackerNoteRemotePointer(t);
    macvncCursorTrackerPollPosition(t, TRUE);
    XCTAssertEqual(screen.cursorX, 0);
    XCTAssertEqual(screen.cursorY, 0);
    macvncCursorTrackerDestroy(t);
    macvncCursorTrackerDestroy(NULL);
}

@end
