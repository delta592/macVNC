/* Shared tiny assert harness for C unit tests (CTest). */
#ifndef MACVNC_TEST_HARNESS_H
#define MACVNC_TEST_HARNESS_H

#include <stdio.h>
#include <stdlib.h>

static int g_macvnc_test_failures = 0;

#define MACVNC_CHECK(cond)                                                                         \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                        \
            g_macvnc_test_failures++;                                                              \
        }                                                                                          \
    } while (0)

#define MACVNC_CHECK_EQ_STR(a, b)                                                                  \
    do {                                                                                           \
        const char *_a = (a);                                                                      \
        const char *_b = (b);                                                                      \
        if (!_a || !_b || strcmp(_a, _b) != 0) {                                                   \
            fprintf(stderr, "FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__,                  \
                    _a ? _a : "(null)", _b ? _b : "(null)");                                       \
            g_macvnc_test_failures++;                                                              \
        }                                                                                          \
    } while (0)

static int
macvncTestFinish(const char *suite)
{
    if (g_macvnc_test_failures == 0) {
        printf("OK %s\n", suite);
        return 0;
    }
    fprintf(stderr, "%s: %d failure(s)\n", suite, g_macvnc_test_failures);
    return 1;
}

#endif /* MACVNC_TEST_HARNESS_H */
