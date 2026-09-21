#include "test_harness.h"

#include "cert_manager.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char g_tmpHome[512];
static char g_savedHome[512];
static int g_hadSavedHome = 0;

static void
setupTempHome(void)
{
    char tmpl[] = "/tmp/macvnc-test-home.XXXXXX";
    char *dir;
    const char *prev = getenv("HOME");

    g_hadSavedHome = 0;
    if (prev && *prev) {
        snprintf(g_savedHome, sizeof(g_savedHome), "%s", prev);
        g_hadSavedHome = 1;
    }

    dir = mkdtemp(tmpl);
    if (!dir) {
        perror("mkdtemp");
        exit(2);
    }
    snprintf(g_tmpHome, sizeof(g_tmpHome), "%s", dir);
    setenv("HOME", g_tmpHome, 1);
}

static void
cleanupTempHome(void)
{
    char cmd[640];

    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_tmpHome);
    system(cmd);

    if (g_hadSavedHome)
        setenv("HOME", g_savedHome, 1);
    else
        unsetenv("HOME");
}

static void
testGetPaths(void)
{
    char cert[512];
    char key[512];
    char expectCert[512];
    char expectKey[512];

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    snprintf(expectCert, sizeof(expectCert), "%s/.macvnc/cert.pem", g_tmpHome);
    snprintf(expectKey, sizeof(expectKey), "%s/.macvnc/key.pem", g_tmpHome);
    MACVNC_CHECK_EQ_STR(cert, expectCert);
    MACVNC_CHECK_EQ_STR(key, expectKey);
}

static void
testGetPathsRejectsMissingHome(void)
{
    char cert[64];
    char key[64];

    unsetenv("HOME");
    MACVNC_CHECK(!macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));

    setenv("HOME", "", 1);
    MACVNC_CHECK(!macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));

    setenv("HOME", g_tmpHome, 1);
}

static void
testGetPathsRejectsTinyBuffers(void)
{
    char cert[512];
    char key[512];
    char tiny[8];

    MACVNC_CHECK(!macvncCertGetPaths(tiny, sizeof(tiny), key, sizeof(key)));
    MACVNC_CHECK(!macvncCertGetPaths(cert, sizeof(cert), tiny, sizeof(tiny)));
}

static void
testEnsureCreatesFiles(void)
{
    char cert[512];
    char key[512];
    struct stat st;

    MACVNC_CHECK(macvncCertEnsure(FALSE));
    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    MACVNC_CHECK(stat(cert, &st) == 0);
    MACVNC_CHECK(stat(key, &st) == 0);
    MACVNC_CHECK((st.st_mode & 0777) == 0600);
}

static void
testEnsureIdempotent(void)
{
    char cert[512];
    char key[512];
    struct stat beforeCert, afterCert;

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    MACVNC_CHECK(stat(cert, &beforeCert) == 0);
    MACVNC_CHECK(macvncCertEnsure(FALSE));
    MACVNC_CHECK(stat(cert, &afterCert) == 0);
    MACVNC_CHECK(beforeCert.st_mtime == afterCert.st_mtime);
    MACVNC_CHECK(beforeCert.st_size == afterCert.st_size);
}

static int
readFile(const char *path, unsigned char *buf, size_t bufSize, size_t *outLen)
{
    FILE *fp = fopen(path, "rb");
    size_t n;

    if (!fp)
        return -1;
    n = fread(buf, 1, bufSize, fp);
    fclose(fp);
    if (n == 0 || n >= bufSize)
        return -1;
    *outLen = n;
    return 0;
}

static void
testForceRegen(void)
{
    char cert[512];
    char key[512];
    unsigned char before[8192];
    unsigned char after[8192];
    size_t beforeLen = 0;
    size_t afterLen = 0;
    struct stat st;

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    MACVNC_CHECK(readFile(cert, before, sizeof(before), &beforeLen) == 0);

    MACVNC_CHECK(macvncCertEnsure(TRUE));

    MACVNC_CHECK(readFile(cert, after, sizeof(after), &afterLen) == 0);
    MACVNC_CHECK(beforeLen != afterLen || memcmp(before, after, beforeLen) != 0);

    MACVNC_CHECK(stat(key, &st) == 0);
    MACVNC_CHECK((st.st_mode & 0777) == 0600);
}

static void
testEnsureWhenOnlyKeyExists(void)
{
    char cert[512];
    char key[512];
    FILE *fp;
    struct stat st;

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    unlink(cert);
    MACVNC_CHECK(stat(key, &st) == 0);

    MACVNC_CHECK(macvncCertEnsure(FALSE));
    MACVNC_CHECK(stat(cert, &st) == 0);

    fp = fopen(cert, "r");
    MACVNC_CHECK(fp != NULL);
    if (fp)
        fclose(fp);
}

static void
testLogFingerprint(void)
{
    /* Happy path with a real cert already on disk. */
    macvncCertLogFingerprint();
}

static void
testLogFingerprintMissingCert(void)
{
    char cert[512];
    char key[512];

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    unlink(cert);
    macvncCertLogFingerprint(); /* fopen fails → early return */
    /* Restore a cert for later tests / cleanup hygiene. */
    MACVNC_CHECK(macvncCertEnsure(FALSE));
}

static void
testLogFingerprintCorruptCert(void)
{
    char cert[512];
    char key[512];
    FILE *fp;

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    fp = fopen(cert, "w");
    MACVNC_CHECK(fp != NULL);
    fputs("not-a-pem-certificate\n", fp);
    fclose(fp);

    macvncCertLogFingerprint(); /* PEM_read_X509 fails → early return */
    MACVNC_CHECK(macvncCertEnsure(TRUE));
}

static void
testEnsureFailsWithoutHome(void)
{
    unsetenv("HOME");
    MACVNC_CHECK(!macvncCertEnsure(FALSE));
    setenv("HOME", g_tmpHome, 1);
}

static void
testLogFingerprintWithoutHome(void)
{
    unsetenv("HOME");
    macvncCertLogFingerprint();
    setenv("HOME", g_tmpHome, 1);
}

static void
testEnsureFailsWhenHomeNotWritable(void)
{
    char cert[512];
    char key[512];
    char macvncDir[640];

    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    unlink(cert);
    unlink(key);
    snprintf(macvncDir, sizeof(macvncDir), "%s/.macvnc", g_tmpHome);
    rmdir(macvncDir);

    /* mkdir(~/.macvnc) fails with EACCES → mkdirRecursive error path. */
    MACVNC_CHECK(chmod(g_tmpHome, 0555) == 0);
    MACVNC_CHECK(!macvncCertEnsure(FALSE));
    MACVNC_CHECK(chmod(g_tmpHome, 0755) == 0);
}

static void
testEnsureFailsWhenCertDirBlockedByFile(void)
{
    char blocker[640];
    char cert[512];
    char key[512];
    FILE *fp;

    /*
     * A regular file at ~/.macvnc makes mkdir() return EEXIST (treated as OK),
     * then fopen(~/.macvnc/cert.pem) fails with ENOTDIR.
     */
    MACVNC_CHECK(macvncCertGetPaths(cert, sizeof(cert), key, sizeof(key)));
    unlink(cert);
    unlink(key);
    snprintf(blocker, sizeof(blocker), "%s/.macvnc", g_tmpHome);
    rmdir(blocker);
    fp = fopen(blocker, "w");
    MACVNC_CHECK(fp != NULL);
    fputs("blocked\n", fp);
    fclose(fp);

    MACVNC_CHECK(!macvncCertEnsure(FALSE));

    unlink(blocker);
}

int
main(void)
{
    setupTempHome();
    atexit(cleanupTempHome);

    testGetPaths();
    testGetPathsRejectsMissingHome();
    testGetPathsRejectsTinyBuffers();
    testEnsureCreatesFiles();
    testEnsureIdempotent();
    testForceRegen();
    testEnsureWhenOnlyKeyExists();
    testLogFingerprint();
    testLogFingerprintMissingCert();
    testLogFingerprintCorruptCert();
    testEnsureFailsWithoutHome();
    testLogFingerprintWithoutHome();
    testEnsureFailsWhenHomeNotWritable();
    testEnsureFailsWhenCertDirBlockedByFile();

    return macvncTestFinish("cert_manager");
}
