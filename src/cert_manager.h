#ifndef MACVNC_CERT_MANAGER_H
#define MACVNC_CERT_MANAGER_H

#include <rfb/rfb.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Directory: ~/Library/Application Support/macVNC */
rfbBool macvncCertGetPaths(char *certPath, size_t certPathSize,
                           char *keyPath, size_t keyPathSize);

/**
 * Ensure a self-signed cert/key pair exists.
 * If forceRegen is true, always create a new pair.
 * Private key is written mode 0600.
 */
rfbBool macvncCertEnsure(rfbBool forceRegen);

/** Log SHA-256 fingerprint of the current certificate (best-effort). */
void macvncCertLogFingerprint(void);

#ifdef __cplusplus
}
#endif

#endif /* MACVNC_CERT_MANAGER_H */
