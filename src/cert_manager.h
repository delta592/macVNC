#ifndef MACVNC_CERT_MANAGER_H
#define MACVNC_CERT_MANAGER_H

#include <rfb/rfb.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Paths under ~/.macvnc/ (no spaces — TigerVNC -X509CA compatible). */
rfbBool macvncCertGetPaths(char *certPath, size_t certPathSize, char *keyPath, size_t keyPathSize);

/**
 * Ensure a self-signed cert/key pair exists.
 * If forceRegen is true, always create a new pair.
 * Private key is created mode 0600; certificate mode 0644 (via open+fchmod).
 */
rfbBool macvncCertEnsure(rfbBool forceRegen);

/** Log SHA-256 fingerprint of the current certificate (best-effort). */
void macvncCertLogFingerprint(void);

#ifdef __cplusplus
}
#endif

#endif /* MACVNC_CERT_MANAGER_H */
