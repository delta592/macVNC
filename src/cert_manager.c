#include "cert_manager.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

static rfbBool
mkdirRecursive(const char *dir, mode_t mode)
{
    char tmp[512];
    size_t len;
    size_t i;

    if (!dir || !*dir)
        return FALSE;

    snprintf(tmp, sizeof(tmp), "%s", dir);
    len = strlen(tmp);
    if (len == 0 || len >= sizeof(tmp))
        return FALSE;

    for (i = 1; i < len; i++) {
        if (tmp[i] != '/')
            continue;
        tmp[i] = '\0';
        if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
            rfbErr("cert: cannot create directory %s: %s\n", tmp, strerror(errno));
            return FALSE;
        }
        tmp[i] = '/';
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST) {
        rfbErr("cert: cannot create directory %s: %s\n", tmp, strerror(errno));
        return FALSE;
    }
    return TRUE;
}

static rfbBool
ensureParentDir(const char *filePath)
{
    char dir[512];
    char *slash;

    snprintf(dir, sizeof(dir), "%s", filePath);
    slash = strrchr(dir, '/');
    if (!slash)
        return FALSE;
    *slash = '\0';

    return mkdirRecursive(dir, 0700);
}

rfbBool
macvncCertGetPaths(char *certPath, size_t certPathSize, char *keyPath, size_t keyPathSize)
{
    const char *home = getenv("HOME");
    if (!home || !*home) {
        rfbErr("cert: HOME is not set\n");
        return FALSE;
    }

    /*
     * Use ~/.macvnc (no spaces). TigerVNC's -X509CA rejects paths with spaces,
     * which rules out ~/Library/Application Support/... for client trust setup.
     */
    if (snprintf(certPath, certPathSize, "%s/.macvnc/cert.pem", home) >= (int)certPathSize)
        return FALSE;
    if (snprintf(keyPath, keyPathSize, "%s/.macvnc/key.pem", home) >= (int)keyPathSize)
        return FALSE;
    return TRUE;
}

static rfbBool
addSanExtensions(X509 *x509)
{
    char hostname[256];
    char san[1024];
    X509_EXTENSION *ext = NULL;
    X509V3_CTX ctx;
    rfbBool ok = FALSE;

    hostname[0] = '\0';
    if (gethostname(hostname, sizeof(hostname)) != 0)
        hostname[0] = '\0';
    hostname[sizeof(hostname) - 1] = '\0';

    /*
     * Cover common local connection targets. LAN IPs still need the viewer to
     * accept the cert once (or regenerate later with a custom cert).
     */
    if (hostname[0]) {
        snprintf(san, sizeof(san), "DNS:localhost,DNS:%s,IP:127.0.0.1,IP:::1", hostname);
    } else {
        snprintf(san, sizeof(san), "DNS:localhost,IP:127.0.0.1,IP:::1");
    }

    X509V3_set_ctx(&ctx, x509, x509, NULL, NULL, 0);
    ext = X509V3_EXT_nconf_nid(NULL, &ctx, NID_subject_alt_name, san);
    if (!ext) {
        rfbErr("cert: failed to build subjectAltName (%s)\n", san);
        goto done;
    }
    if (X509_add_ext(x509, ext, -1) != 1) {
        rfbErr("cert: failed to add subjectAltName\n");
        goto done;
    }
    rfbLog("cert: subjectAltName = %s\n", san);
    ok = TRUE;

done:
    X509_EXTENSION_free(ext);
    return ok;
}

static rfbBool
writeSelfSignedCert(const char *certPath, const char *keyPath)
{
    EVP_PKEY *pkey = NULL;
    X509 *x509 = NULL;
    FILE *keyFile = NULL;
    FILE *certFile = NULL;
    X509_NAME *name;
    char hostname[256];
    const char *cn = "localhost";
    rfbBool ok = FALSE;

    if (!ensureParentDir(certPath) || !ensureParentDir(keyPath))
        return FALSE;

    pkey = EVP_RSA_gen(2048);
    if (!pkey) {
        rfbErr("cert: EVP_RSA_gen failed\n");
        goto done;
    }

    x509 = X509_new();
    if (!x509) {
        rfbErr("cert: X509_new failed\n");
        goto done;
    }

    if (X509_set_version(x509, 2) != 1) /* X509 v3 */
        goto done;
    if (!ASN1_INTEGER_set(X509_get_serialNumber(x509), 1))
        goto done;
    X509_gmtime_adj(X509_get_notBefore(x509), 0);
    X509_gmtime_adj(X509_get_notAfter(x509), 60L * 60L * 24L * 3650L);
    if (!X509_set_pubkey(x509, pkey))
        goto done;

    if (gethostname(hostname, sizeof(hostname)) == 0 && hostname[0]) {
        hostname[sizeof(hostname) - 1] = '\0';
        cn = hostname;
    }

    name = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (unsigned char *)cn, -1, -1, 0);
    X509_set_issuer_name(x509, name);

    if (!addSanExtensions(x509))
        goto done;

    if (!X509_sign(x509, pkey, EVP_sha256())) {
        rfbErr("cert: X509_sign failed\n");
        goto done;
    }

    keyFile = fopen(keyPath, "w");
    if (!keyFile) {
        rfbErr("cert: cannot write %s: %s\n", keyPath, strerror(errno));
        goto done;
    }
    if (!PEM_write_PrivateKey(keyFile, pkey, NULL, NULL, 0, NULL, NULL)) {
        rfbErr("cert: PEM_write_PrivateKey failed\n");
        goto done;
    }
    fclose(keyFile);
    keyFile = NULL;
    chmod(keyPath, 0600);

    certFile = fopen(certPath, "w");
    if (!certFile) {
        rfbErr("cert: cannot write %s: %s\n", certPath, strerror(errno));
        goto done;
    }
    if (!PEM_write_X509(certFile, x509)) {
        rfbErr("cert: PEM_write_X509 failed\n");
        goto done;
    }

    ok = TRUE;
    rfbLog("cert: wrote self-signed certificate to %s (CN=%s)\n", certPath, cn);
    rfbLog("cert: wrote private key to %s (mode 0600)\n", keyPath);

done:
    if (keyFile)
        fclose(keyFile);
    if (certFile)
        fclose(certFile);
    X509_free(x509);
    EVP_PKEY_free(pkey);
    return ok;
}

rfbBool
macvncCertEnsure(rfbBool forceRegen)
{
    char certPath[512];
    char keyPath[512];
    struct stat st;

    if (!macvncCertGetPaths(certPath, sizeof(certPath), keyPath, sizeof(keyPath)))
        return FALSE;

    if (!forceRegen && stat(certPath, &st) == 0 && stat(keyPath, &st) == 0) {
        return TRUE;
    }

    if (forceRegen)
        rfbLog("cert: regenerating certificate (-regen-cert)\n");
    else
        rfbLog("cert: no existing certificate; generating one\n");

    return writeSelfSignedCert(certPath, keyPath);
}

void
macvncCertLogFingerprint(void)
{
    char certPath[512];
    char keyPath[512];
    FILE *fp;
    X509 *x509;
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int mdLen = 0;
    unsigned int i;

    if (!macvncCertGetPaths(certPath, sizeof(certPath), keyPath, sizeof(keyPath)))
        return;

    fp = fopen(certPath, "r");
    if (!fp)
        return;

    x509 = PEM_read_X509(fp, NULL, NULL, NULL);
    fclose(fp);
    if (!x509)
        return;

    if (X509_digest(x509, EVP_sha256(), md, &mdLen)) {
        rfbLog("cert: SHA-256 fingerprint: ");
        for (i = 0; i < mdLen; i++) {
            fprintf(stderr, "%02X%s", md[i], (i + 1 < mdLen) ? ":" : "\n");
        }
    }

    rfbLog("cert: TigerVNC trust: -X509CA %s\n", certPath);
    X509_free(x509);
}
