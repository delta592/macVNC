#include "test_harness.h"

#include "vencrypt.h"

#include <string.h>

static void
testModeNames(void)
{
    const char *x509 = macvncSecurityModeName(MACVNC_SECURITY_VENCRYPT_X509);
    const char *anon = macvncSecurityModeName(MACVNC_SECURITY_ANONTLS);
    const char *plain = macvncSecurityModeName(MACVNC_SECURITY_PLAIN);
    const char *unknown = macvncSecurityModeName((MacVNCSecurityMode)99);

    MACVNC_CHECK(x509 != NULL);
    MACVNC_CHECK(anon != NULL);
    MACVNC_CHECK(plain != NULL);
    MACVNC_CHECK(strstr(x509, "VeNCrypt") != NULL);
    MACVNC_CHECK(strstr(anon, "AnonTLS") != NULL);
    MACVNC_CHECK(strstr(plain, "UNENCRYPTED") != NULL);
    MACVNC_CHECK_EQ_STR(unknown, "unknown");
}

int
main(void)
{
    testModeNames();
    return macvncTestFinish("security_mode");
}
