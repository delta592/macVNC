#include "vencrypt.h"
#include "cert_manager.h"

#include <rfb/rfbconfig.h>
#include <rfb/rfbproto.h>

#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include <openssl/err.h>
#include <openssl/ssl.h>

#if defined(LIBVNCSERVER_HAVE_GNUTLS)
#include <gnutls/gnutls.h>
#endif

#if !defined(LIBVNCSERVER_HAVE_LIBSSL) && !defined(LIBVNCSERVER_HAVE_GNUTLS)
#error "libvncserver must be built with OpenSSL or GnuTLS for TLS"
#endif
#if !defined(LIBVNCSERVER_WITH_WEBSOCKETS)
#error "libvncserver must be built with WebSockets (TLS socket I/O path)"
#endif

/* libvncserver backend entry — works for both OpenSSL and GnuTLS builds */
extern int rfbssl_init(rfbClientPtr cl);

/* Not a real RFB type — kept in the handler list but ignored by viewers. */
#define MACVNC_DISABLED_SEC_TYPE 254

static MacVNCSecurityMode gSecurityMode = MACVNC_SECURITY_VENCRYPT_X509;
static rfbPasswordCheckProcPtr gOriginalPasswordCheck = NULL;
static char *gDummyPasswdList[2] = {"__macvnc_block_unencrypted__", NULL};
static rfbBool gOwnPasswdList = FALSE;

/*
 * libvncserver always prepends VncAuth/None before custom handlers, and
 * TigerVNC 1.14 picks the first offered type it supports. Locate those
 * stock handlers in the dylib and change their type byte so encrypted
 * mode effectively advertises VeNCrypt only.
 */
static void *
findLibVncLocalSymbol(const char *symname)
{
    uint32_t i, n = _dyld_image_count();

    for (i = 0; i < n; i++) {
        const char *imageName = _dyld_get_image_name(i);
        const struct mach_header_64 *mh;
        intptr_t slide;
        const uint8_t *cmd;
        uint32_t c;
        const struct symtab_command *symtab = NULL;
        const struct segment_command_64 *linkedit = NULL;

        if (!imageName || !strstr(imageName, "libvncserver"))
            continue;

        mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64)
            continue;

        slide = _dyld_get_image_vmaddr_slide(i);
        cmd = (const uint8_t *)(mh + 1);
        for (c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmd;
            if (lc->cmd == LC_SYMTAB)
                symtab = (const struct symtab_command *)lc;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
                if (strcmp(sg->segname, "__LINKEDIT") == 0)
                    linkedit = sg;
            }
            cmd += lc->cmdsize;
        }
        if (!symtab || !linkedit)
            continue;

        {
            const uint8_t *linkeditBase =
                (const uint8_t *)(linkedit->vmaddr + slide - linkedit->fileoff);
            const struct nlist_64 *syms = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
            const char *strs = (const char *)(linkeditBase + symtab->stroff);
            uint32_t s;

            for (s = 0; s < symtab->nsyms; s++) {
                const char *sn;
                if (syms[s].n_un.n_strx == 0)
                    continue;
                sn = strs + syms[s].n_un.n_strx;
                if (strcmp(sn, symname) == 0)
                    return (void *)(syms[s].n_value + slide);
            }
        }
    }
    return NULL;
}

static void
neuterStockSecurityHandler(const char *symname)
{
    rfbSecurityHandler *handler = findLibVncLocalSymbol(symname);
    if (!handler) {
        rfbErr("vencrypt: could not locate %s — older viewers may still "
               "prefer plain VncAuth; use -SecurityTypes=X509Vnc\n",
               symname);
        return;
    }
    rfbLog("vencrypt: disabling stock security type %u (%s) for encrypted mode\n", handler->type,
           symname);
    handler->type = MACVNC_DISABLED_SEC_TYPE;
}

static void
disableStockUnencryptedTypes(void)
{
    /*
     * Force libvncserver to load so local symbols are mapped before we search.
     */
    dlopen(NULL, RTLD_NOW);
    neuterStockSecurityHandler("_VncSecurityHandlerVncAuth");
    neuterStockSecurityHandler("_VncSecurityHandlerNone");
}

static void
logSslErrors(const char *where)
{
#if defined(LIBVNCSERVER_HAVE_LIBSSL)
    unsigned long e;
    char buf[256];

    while ((e = ERR_get_error()) != 0) {
        ERR_error_string_n(e, buf, sizeof(buf));
        rfbErr("vencrypt: %s: %s\n", where, buf);
    }
#else
    (void)where;
#endif
}

#if defined(LIBVNCSERVER_HAVE_LIBSSL)
/* Must match libvncserver rfbssl_openssl.c */
struct rfbssl_openssl_ctx {
    SSL_CTX *ssl_ctx;
    SSL *ssl;
};

static void
freeOpensslCtx(struct rfbssl_openssl_ctx *ctx)
{
    if (!ctx)
        return;
    if (ctx->ssl)
        SSL_free(ctx->ssl);
    if (ctx->ssl_ctx)
        SSL_CTX_free(ctx->ssl_ctx);
    free(ctx);
}

static int
sslAcceptWithWait(SSL *ssl, int fd, int timeoutSec)
{
    int r;
    time_t deadline = time(NULL) + timeoutSec;

    for (;;) {
        r = SSL_accept(ssl);
        if (r == 1)
            return 0;

        int err = SSL_get_error(ssl, r);
        if (err != SSL_ERROR_WANT_READ && err != SSL_ERROR_WANT_WRITE) {
            rfbErr("vencrypt: SSL_accept failed (ssl_error=%d errno=%d)\n", err, errno);
            logSslErrors("SSL_accept");
            if (err == SSL_ERROR_SSL) {
                rfbErr("vencrypt: tip: TigerVNC must trust this cert — accept the "
                       "viewer dialog, or pass -X509CA ~/.macvnc/cert.pem\n");
            }
            return -1;
        }

        if (time(NULL) >= deadline) {
            rfbErr("vencrypt: TLS handshake timed out after %d seconds "
                   "(viewer may be waiting on a certificate dialog)\n",
                   timeoutSec);
            return -1;
        }

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        r = select(fd + 1, err == SSL_ERROR_WANT_READ ? &fds : NULL,
                   err == SSL_ERROR_WANT_WRITE ? &fds : NULL, NULL, &tv);
        if (r < 0 && errno != EINTR) {
            rfbErr("vencrypt: select failed: %s\n", strerror(errno));
            return -1;
        }
    }
}

static int
tlsAcceptAnonOpenSSL(rfbClientPtr cl)
{
    struct rfbssl_openssl_ctx *ctx;

    SSL_library_init();
    SSL_load_error_strings();

    ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        rfbErr("vencrypt: OOM\n");
        return -1;
    }

    ctx->ssl_ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx->ssl_ctx) {
        rfbErr("vencrypt: SSL_CTX_new failed\n");
        logSslErrors("SSL_CTX_new");
        free(ctx);
        return -1;
    }

    SSL_CTX_set_security_level(ctx->ssl_ctx, 0);
    if (SSL_CTX_set_cipher_list(ctx->ssl_ctx, "aNULL:@SECLEVEL=0") != 1) {
        rfbErr("vencrypt: failed to enable anonymous TLS ciphers "
               "(OpenSSL may have removed aNULL support)\n");
        logSslErrors("cipher_list");
        freeOpensslCtx(ctx);
        return -1;
    }
#if defined(SSL_CTX_set_max_proto_version)
    SSL_CTX_set_max_proto_version(ctx->ssl_ctx, TLS1_2_VERSION);
#endif

    ctx->ssl = SSL_new(ctx->ssl_ctx);
    if (!ctx->ssl || !SSL_set_fd(ctx->ssl, cl->sock)) {
        rfbErr("vencrypt: SSL_new/SSL_set_fd failed\n");
        logSslErrors("SSL_new");
        freeOpensslCtx(ctx);
        return -1;
    }

    if (sslAcceptWithWait(ctx->ssl, cl->sock, 60) != 0) {
        freeOpensslCtx(ctx);
        return -1;
    }

    cl->sslctx = (rfbSslCtx *)ctx;
    return 0;
}
#endif /* LIBVNCSERVER_HAVE_LIBSSL */

#if defined(LIBVNCSERVER_HAVE_GNUTLS)
/* Must match libvncserver rfbssl_gnutls.c */
struct rfbssl_gnutls_ctx {
    char peekbuf[2048];
    int peeklen;
    int peekstart;
    gnutls_session_t session;
    gnutls_certificate_credentials_t x509_cred;
    gnutls_dh_params_t dh_params;
};

static int
tlsAcceptAnonGnuTLS(rfbClientPtr cl)
{
    struct rfbssl_gnutls_ctx *ctx;
    gnutls_anon_server_credentials_t anon_cred = NULL;
    int ret;

    ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        rfbErr("vencrypt: OOM\n");
        return -1;
    }

    gnutls_global_init();
    if ((ret = gnutls_certificate_allocate_credentials(&ctx->x509_cred)) != GNUTLS_E_SUCCESS)
        goto fail;
    if ((ret = gnutls_init(&ctx->session, GNUTLS_SERVER)) != GNUTLS_E_SUCCESS)
        goto fail;
    if ((ret = gnutls_anon_allocate_server_credentials(&anon_cred)) != GNUTLS_E_SUCCESS)
        goto fail;
    if ((ret = gnutls_credentials_set(ctx->session, GNUTLS_CRD_ANON, anon_cred)) !=
        GNUTLS_E_SUCCESS)
        goto fail;
    if ((ret = gnutls_priority_set_direct(ctx->session, "NORMAL:+ANON-ECDH:+ANON-DH", NULL)) !=
        GNUTLS_E_SUCCESS)
        goto fail;

    gnutls_transport_set_ptr(ctx->session, (gnutls_transport_ptr_t)(uintptr_t)cl->sock);

    do {
        ret = gnutls_handshake(ctx->session);
    } while (ret == GNUTLS_E_AGAIN || ret == GNUTLS_E_INTERRUPTED);

    if (ret != GNUTLS_E_SUCCESS) {
        rfbErr("vencrypt: GnuTLS anon handshake failed: %s\n", gnutls_strerror(ret));
        goto fail;
    }

    /*
     * anon_cred must outlive the session; rfbssl_destroy only frees x509_cred.
     * Intentionally leak anon_cred for the process lifetime of rare AnonTLS
     * sessions (MacPorts / GnuTLS builds).
     */
    (void)anon_cred;
    cl->sslctx = (rfbSslCtx *)ctx;
    return 0;

fail:
    if (ctx->session)
        gnutls_deinit(ctx->session);
    if (anon_cred)
        gnutls_anon_free_server_credentials(anon_cred);
    if (ctx->x509_cred)
        gnutls_certificate_free_credentials(ctx->x509_cred);
    free(ctx);
    return -1;
}
#endif /* LIBVNCSERVER_HAVE_GNUTLS */

static int
tlsAcceptAnon(rfbClientPtr cl)
{
#if defined(LIBVNCSERVER_HAVE_LIBSSL)
    return tlsAcceptAnonOpenSSL(cl);
#elif defined(LIBVNCSERVER_HAVE_GNUTLS)
    return tlsAcceptAnonGnuTLS(cl);
#else
    (void)cl;
    rfbErr("vencrypt: AnonTLS requires OpenSSL or GnuTLS in libvncserver\n");
    return -1;
#endif
}

/*
 * Use libvncserver's rfbssl_init so the sslctx layout matches the linked
 * backend (OpenSSL on Homebrew, GnuTLS on MacPorts).
 */
static int
tlsAcceptX509(rfbClientPtr cl)
{
    if (!cl->screen->sslcertfile || !cl->screen->sslcertfile[0]) {
        rfbErr("vencrypt: no certificate configured\n");
        return -1;
    }
    if (rfbssl_init(cl) != 0) {
        rfbErr("vencrypt: rfbssl_init failed (check cert/key; "
               "TigerVNC may need -X509CA ~/.macvnc/cert.pem)\n");
        logSslErrors("rfbssl_init");
        return -1;
    }
    return 0;
}

static rfbBool
macvncPasswordCheck(rfbClientPtr cl, const char *response, int len)
{
    if (gSecurityMode != MACVNC_SECURITY_PLAIN && !cl->sslctx) {
        rfbLog("Rejecting unencrypted VNC authentication attempt\n");
        return FALSE;
    }
    if (gOriginalPasswordCheck)
        return gOriginalPasswordCheck(cl, response, len);
    return FALSE;
}

static void
sendAuthOkAndInit(rfbClientPtr cl)
{
    uint32_t authResult;

    if (cl->protocolMajorVersion == 3 && cl->protocolMinorVersion > 7 &&
        cl->protocolMinorVersion != 889) {
        authResult = Swap32IfLE(rfbVncAuthOK);
        if (rfbWriteExact(cl, (char *)&authResult, 4) < 0) {
            rfbLogPerror("vencrypt: write SecurityResult");
            rfbCloseClient(cl);
            return;
        }
    }

    cl->state = (cl->protocolMinorVersion == 889) ? RFB_INITIALISATION_SHARED : RFB_INITIALISATION;
    if (cl->state == RFB_INITIALISATION_SHARED)
        rfbProcessClientMessage(cl);
}

static void
sendVncAuthChallenge(rfbClientPtr cl)
{
    rfbRandomBytes(cl->authChallenge);
    if (rfbWriteExact(cl, (char *)cl->authChallenge, CHALLENGESIZE) < 0) {
        rfbLogPerror("vencrypt: write auth challenge");
        rfbCloseClient(cl);
        return;
    }
    cl->state = RFB_AUTHENTICATION;
}

static void
handleVeNCrypt(rfbClientPtr cl)
{
    uint8_t serverVersion[2] = {0, 2};
    uint8_t clientVersion[2];
    uint8_t reply;
    uint8_t count;
    uint32_t subtypes[4];
    uint32_t chosen = 0;
    uint32_t wire;
    int i, n;
    int wantPassword;
    int useAnon;
    int tlsOk;

    if (rfbWriteExact(cl, (char *)serverVersion, 2) < 0) {
        rfbLogPerror("vencrypt: write version");
        rfbCloseClient(cl);
        return;
    }

    n = rfbReadExact(cl, (char *)clientVersion, 2);
    if (n <= 0) {
        rfbCloseClient(cl);
        return;
    }

    if (clientVersion[0] != 0 || clientVersion[1] < 2) {
        reply = 0xFF;
        rfbWriteExact(cl, (char *)&reply, 1);
        rfbLog("vencrypt: client version %d.%d unsupported\n", clientVersion[0], clientVersion[1]);
        rfbCloseClient(cl);
        return;
    }
    reply = 0;
    if (rfbWriteExact(cl, (char *)&reply, 1) < 0) {
        rfbCloseClient(cl);
        return;
    }

    wantPassword = (gOriginalPasswordCheck != NULL && !gOwnPasswdList);
    useAnon = (gSecurityMode == MACVNC_SECURITY_ANONTLS);

    count = 0;
    if (useAnon) {
        subtypes[count++] = wantPassword ? rfbVeNCryptTLSVNC : rfbVeNCryptTLSNone;
    } else {
        subtypes[count++] = wantPassword ? rfbVeNCryptX509VNC : rfbVeNCryptX509None;
    }

    if (rfbWriteExact(cl, (char *)&count, 1) < 0) {
        rfbCloseClient(cl);
        return;
    }
    for (i = 0; i < count; i++) {
        wire = Swap32IfLE(subtypes[i]);
        if (rfbWriteExact(cl, (char *)&wire, 4) < 0) {
            rfbCloseClient(cl);
            return;
        }
    }

    n = rfbReadExact(cl, (char *)&wire, 4);
    if (n <= 0) {
        rfbCloseClient(cl);
        return;
    }
    chosen = Swap32IfLE(wire);

    for (i = 0; i < count; i++) {
        if (chosen == subtypes[i])
            break;
    }
    if (i >= count) {
        rfbLog("vencrypt: client chose unsupported subtype %u\n", chosen);
        rfbCloseClient(cl);
        return;
    }

    rfbLog("vencrypt: subtype %u selected\n", chosen);

    /* VeNCrypt TLS subtypes: server must send a status byte before TLS.
     * 1 = proceed with handshake, 0 = failure (TigerVNC / GnuTLS clients). */
    {
        uint8_t tlsStatus = 1;
        if (rfbWriteExact(cl, (char *)&tlsStatus, 1) < 0) {
            rfbLogPerror("vencrypt: write TLS status");
            rfbCloseClient(cl);
            return;
        }
    }

    switch (chosen) {
    case rfbVeNCryptTLSNone:
    case rfbVeNCryptTLSVNC:
        tlsOk = tlsAcceptAnon(cl);
        break;
    case rfbVeNCryptX509None:
    case rfbVeNCryptX509VNC:
        tlsOk = tlsAcceptX509(cl);
        break;
    default:
        tlsOk = -1;
        break;
    }

    if (tlsOk != 0) {
        rfbCloseClient(cl);
        return;
    }

    rfbLog("vencrypt: TLS handshake complete — session is encrypted\n");

    switch (chosen) {
    case rfbVeNCryptTLSNone:
    case rfbVeNCryptX509None:
        sendAuthOkAndInit(cl);
        break;
    case rfbVeNCryptTLSVNC:
    case rfbVeNCryptX509VNC:
        sendVncAuthChallenge(cl);
        break;
    default:
        rfbCloseClient(cl);
        break;
    }
}

static rfbSecurityHandler veNCryptHandler = {rfbVeNCrypt, handleVeNCrypt, NULL};

rfbBool
macvncSecuritySetup(rfbScreenInfoPtr screen, MacVNCSecurityMode mode)
{
    char certPath[512];
    char keyPath[512];

    gSecurityMode = mode;

    rfbLog("Security mode: %s\n", macvncSecurityModeName(mode));

    if (mode == MACVNC_SECURITY_PLAIN) {
        rfbLog("WARNING: traffic is NOT encrypted. Prefer -security vencrypt.\n");
        return TRUE;
    }

    gOriginalPasswordCheck = screen->passwordCheck;
    gOwnPasswdList = FALSE;

    /*
     * Keep a password slot so libvncserver does not advertise "None", but
     * neuter the stock VncAuth/None type bytes so the wire list effectively
     * only offers VeNCrypt (needed for TigerVNC 1.14, which picks the first
     * supported type from the server list).
     */
    if (!screen->authPasswdData) {
        screen->authPasswdData = (void *)gDummyPasswdList;
        gOwnPasswdList = TRUE;
        gOriginalPasswordCheck = NULL;
    }
    screen->passwordCheck = macvncPasswordCheck;
    disableStockUnencryptedTypes();

    if (mode == MACVNC_SECURITY_VENCRYPT_X509) {
        if (!macvncCertGetPaths(certPath, sizeof(certPath), keyPath, sizeof(keyPath)))
            return FALSE;
        screen->sslcertfile = strdup(certPath);
        screen->sslkeyfile = strdup(keyPath);
        if (!screen->sslcertfile || !screen->sslkeyfile) {
            rfbErr("vencrypt: strdup failed\n");
            return FALSE;
        }
        macvncCertLogFingerprint();
    } else {
        rfbLog("AnonTLS: server identity is NOT authenticated; "
               "use -security vencrypt for X.509 when possible.\n");
    }

    rfbRegisterSecurityHandler(&veNCryptHandler);
    return TRUE;
}
