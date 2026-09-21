#ifndef MACVNC_VENCRYPT_H
#define MACVNC_VENCRYPT_H

#include <rfb/rfb.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MACVNC_SECURITY_VENCRYPT_X509 = 0,
    MACVNC_SECURITY_ANONTLS,
    MACVNC_SECURITY_PLAIN
} MacVNCSecurityMode;

static inline const char *
macvncSecurityModeName(MacVNCSecurityMode mode)
{
    switch (mode) {
    case MACVNC_SECURITY_VENCRYPT_X509:
        return "VeNCrypt+X.509 (encrypted, default)";
    case MACVNC_SECURITY_ANONTLS:
        return "AnonTLS (encrypted, server identity NOT authenticated)";
    case MACVNC_SECURITY_PLAIN:
        return "plain VNC (UNENCRYPTED — compatibility only)";
    }
    return "unknown";
}

/**
 * Configure encryption for the server.
 * For X.509 mode, cert/key files must already exist (see cert_manager).
 * Registers VeNCrypt and gates unencrypted VNC-auth attempts.
 */
rfbBool macvncSecuritySetup(rfbScreenInfoPtr screen, MacVNCSecurityMode mode);

#ifdef __cplusplus
}
#endif

#endif /* MACVNC_VENCRYPT_H */
