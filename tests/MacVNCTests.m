//
// XCTest entry points for the same logic covered by CTest.
// Build with: cmake -G Xcode -DMACVNC_BUILD_XCTEST=ON ...
// Run with:   xcodebuild test -scheme macVNC -destination 'platform=macOS'
//
// OCMock is reserved for future ScreenCapturer / AppKit isolation tests.
//

#import <XCTest/XCTest.h>

#include "cert_manager.h"
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
