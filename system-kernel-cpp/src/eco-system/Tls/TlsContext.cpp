//===- TlsContext.cpp - OpenSSL contexts for Socket.Tls -------------------===//
//
// See TlsContext.hpp (plans/eco-system-sockets.md §3.6, §D.5). The build
// functions run on SysWorkPool workers: POD and OpenSSL only (G1). The
// process-wide caches (system and no-verification client contexts) are
// guarded by a mutex that is never held while allocating on the Elm heap
// (nothing here touches the heap at all).
//
// Templates used: T2 (worker side, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Tls/TlsContext.hpp"

#ifndef _WIN32

#include "eco-system/Core/IoReactor.hpp"

#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sys/stat.h>

namespace Eco::System {

namespace {

// --- Init and exit (N13) -------------------------------------------------------

void tlsQuiesce() {
    // Stop the reactor dispatching handlers (some may be inside OpenSSL)
    // before the process tears down; at most 100 ms (§3.6).
    (void)IoReactor::instance().quiesce(100);
}

// --- Contexts -------------------------------------------------------------------

std::shared_ptr<ssl_ctx_st> own(SSL_CTX* ctx) {
    return std::shared_ptr<ssl_ctx_st>(ctx, [](ssl_ctx_st* c) { SSL_CTX_free(c); });
}

// The options every context shares (§3.6).
void commonOptions(SSL_CTX* ctx) {
    (void)SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    uint64_t opts = SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_COMPRESSION;
#ifdef SSL_OP_IGNORE_UNEXPECTED_EOF
    opts |= SSL_OP_IGNORE_UNEXPECTED_EOF;   // a FIN without close_notify is Closed (as Node)
#endif
    (void)SSL_CTX_set_options(ctx, opts);
    (void)SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
}

bool fileExists(const char* path) {
    struct stat st;
    return ::stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

bool storeEmpty(SSL_CTX* ctx) {
    X509_STORE* store = SSL_CTX_get_cert_store(ctx);
    if (!store) return true;
    STACK_OF(X509_OBJECT)* objs = X509_STORE_get0_objects(store);
    return !objs || sk_X509_OBJECT_num(objs) == 0;
}

// §3.6 SystemCertificates.
std::shared_ptr<ssl_ctx_st> makeSystemContext(TlsError& err) {
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        err = tlsTakeError("SSL_CTX_new");
        return nullptr;
    }
    auto owned = own(ctx);
    commonOptions(ctx);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nullptr);
    const char* file = std::getenv("SSL_CERT_FILE");
    const char* dir = std::getenv("SSL_CERT_DIR");
    if (file && !*file) file = nullptr;
    if (dir && !*dir) dir = nullptr;
    if (file || dir) {
        // As OpenSSL itself (and Node): the environment overrides the
        // defaults. A file that does not load leaves an empty store; the
        // handshake then fails verification.
        (void)SSL_CTX_load_verify_locations(ctx, file, dir);
        ERR_clear_error();
        return owned;
    }
    (void)SSL_CTX_set_default_verify_paths(ctx);
    ERR_clear_error();
    if (storeEmpty(ctx)) {
        // Static and brew builds point at an OpenSSL prefix that may hold no
        // bundle (N12, R3). A hashed default directory loads lazily and
        // still works; the probe adds a bundle file next to it.
        static const char* const kProbe[] = {
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/ssl/cert.pem",
            "/usr/local/etc/openssl@3/cert.pem",
            "/opt/homebrew/etc/openssl@3/cert.pem",
        };
        for (const char* p : kProbe) {
            if (!fileExists(p)) continue;
            (void)SSL_CTX_load_verify_locations(ctx, p, nullptr);
            ERR_clear_error();
            break;
        }
    }
    return owned;
}

// §3.6 TrustedCertificates: only the certificates in `pem`.
std::shared_ptr<ssl_ctx_st> makeTrustedContext(const std::string& pem, TlsError& err) {
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        err = tlsTakeError("SSL_CTX_new");
        return nullptr;
    }
    auto owned = own(ctx);
    commonOptions(ctx);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nullptr);
    X509_STORE* store = X509_STORE_new();
    if (!store) {
        err = tlsTakeError("X509_STORE_new");
        return nullptr;
    }
    SSL_CTX_set_cert_store(ctx, store);   // the context owns it now
    BIO* bio = BIO_new_mem_buf(pem.data(), static_cast<int>(pem.size()));
    if (!bio) {
        err = tlsTakeError("BIO_new_mem_buf");
        return nullptr;
    }
    int added = 0;
    for (;;) {
        X509* cert = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
        if (!cert) break;
        if (X509_STORE_add_cert(store, cert) == 1) ++added;
        X509_free(cert);
    }
    BIO_free(bio);
    if (added == 0) {
        err = tlsTakeError("trusted certificates");
        if (err.code == "ERR_SSL_UNKNOWN") {
            err.code = "ERR_SSL_NO_CERTIFICATES";
            err.message = "trusted certificates: no certificate found";
        }
        return nullptr;
    }
    ERR_clear_error();   // the loop ends on a "no start line" error
    return owned;
}

std::shared_ptr<ssl_ctx_st> makeNoVerifyContext(TlsError& err) {
    SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        err = tlsTakeError("SSL_CTX_new");
        return nullptr;
    }
    auto owned = own(ctx);
    commonOptions(ctx);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr);
    return owned;
}

// Process-wide caches (any worker thread).
std::mutex& cacheMutex() {
    static auto* m = new std::mutex();   // leaky (§3.4)
    return *m;
}
std::shared_ptr<ssl_ctx_st>& cachedSystem() {
    static auto* p = new std::shared_ptr<ssl_ctx_st>();
    return *p;
}
std::shared_ptr<ssl_ctx_st>& cachedNoVerify() {
    static auto* p = new std::shared_ptr<ssl_ctx_st>();
    return *p;
}

// ALPN list → wire format (length-prefixed). Each protocol 1..255 bytes.
bool alpnWire(const std::vector<std::string>& alpn, std::string& out, TlsError& err) {
    out.clear();
    for (const auto& p : alpn) {
        if (p.empty() || p.size() > 255) {
            err.code = "EINVAL";
            err.message = "alpn EINVAL: a protocol name must be 1 to 255 bytes";
            return false;
        }
        out.push_back(static_cast<char>(p.size()));
        out += p;
    }
    return true;
}

bool isIpLiteral(const std::string& name) {
    if (name.empty()) return false;
    ASN1_OCTET_STRING* ip = a2i_IPADDRESS(name.c_str());
    if (!ip) {
        ERR_clear_error();
        return false;
    }
    ASN1_OCTET_STRING_free(ip);
    return true;
}

// Server ALPN selection (§3.6): the first server protocol the client offers.
// No overlap: a fatal alert, or no ALPN in NoAck mode (websockets plan §3.5).
int alpnSelect(SSL* /*ssl*/, const unsigned char** out, unsigned char* outlen,
               const unsigned char* in, unsigned int inlen, void* arg) {
    auto* cfg = static_cast<TlsServerConfig*>(arg);
    const std::string& srv = cfg->alpnWire;
    for (size_t i = 0; i < srv.size();) {
        size_t sl = static_cast<unsigned char>(srv[i]);
        const char* sp = srv.data() + i + 1;
        for (unsigned int j = 0; j < inlen;) {
            unsigned int cl = in[j];
            if (j + 1 + cl > inlen) break;   // malformed offer
            if (cl == sl && std::memcmp(in + j + 1, sp, sl) == 0) {
                *out = in + j + 1;
                *outlen = static_cast<unsigned char>(cl);
                return SSL_TLSEXT_ERR_OK;
            }
            j += 1 + cl;
        }
        i += 1 + sl;
    }
    if (cfg->alpnNoAck) return SSL_TLSEXT_ERR_NOACK;   // Http.Server: HTTP/1.1 without ALPN
    return SSL_TLSEXT_ERR_ALERT_FATAL;   // no_application_protocol (as Node)
}

// RFC 9113 §9.2.2 / Appendix A: TLS 1.2 suites for HTTP/2 (ECDHE key
// exchange, AEAD ciphers). SSL_CTX_set_cipher_list does not touch TLS 1.3.
const char* const kH2Tls12Ciphers =
    "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:"
    "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:"
    "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";

} // namespace

// ---------------------------------------------------------------------------

void ensureTlsInit() {
    static bool done = false;   // main thread only
    if (done) return;
    done = true;
    (void)OPENSSL_init_ssl(OPENSSL_INIT_NO_ATEXIT | OPENSSL_INIT_LOAD_SSL_STRINGS |
                               OPENSSL_INIT_LOAD_CRYPTO_STRINGS,
                           nullptr);
    (void)IoReactor::instance();   // exists before the quiesce can be asked for
    std::atexit(&tlsQuiesce);
}

std::string tlsErrorCode(unsigned long e) {
    const char* reason = e != 0 ? ERR_reason_error_string(e) : nullptr;
    if (!reason || !*reason) return "ERR_SSL_UNKNOWN";
    std::string code = "ERR_SSL_";
    for (const char* p = reason; *p; ++p) {
        unsigned char ch = static_cast<unsigned char>(*p);
        code.push_back(ch == ' ' ? '_' : static_cast<char>(std::toupper(ch)));
    }
    return code;
}

std::string tlsErrorMessage(unsigned long e) {
    if (e == 0) return "unknown TLS error";
    char buf[256];
    ERR_error_string_n(e, buf, sizeof(buf));
    return std::string(buf);
}

std::string tlsVerifyCode(long v) {
    switch (v) {
    case X509_V_ERR_CERT_HAS_EXPIRED: return "CERT_HAS_EXPIRED";
    case X509_V_ERR_CERT_NOT_YET_VALID: return "CERT_NOT_YET_VALID";
    case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT: return "DEPTH_ZERO_SELF_SIGNED_CERT";
    case X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN: return "SELF_SIGNED_CERT_IN_CHAIN";
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY: return "UNABLE_TO_GET_ISSUER_CERT_LOCALLY";
    case X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE: return "UNABLE_TO_VERIFY_LEAF_SIGNATURE";
    case X509_V_ERR_CERT_REVOKED: return "CERT_REVOKED";
    case X509_V_ERR_HOSTNAME_MISMATCH:
    case X509_V_ERR_IP_ADDRESS_MISMATCH: return "ERR_TLS_CERT_ALTNAME_INVALID";
    default: return "CERT_VERIFY_FAILED";
    }
}

TlsError tlsTakeError(const char* what) {
    unsigned long e = ERR_get_error();
    TlsError err;
    err.code = tlsErrorCode(e);
    err.message = std::string(what) + ": " + tlsErrorMessage(e);
    ERR_clear_error();
    return err;
}

std::shared_ptr<TlsClientConfig> buildTlsClientConfig(int64_t mode, const std::string& pem,
                                                      const std::string& serverName,
                                                      const std::vector<std::string>& alpn,
                                                      TlsError& err) {
    ERR_clear_error();
    auto cfg = std::make_shared<TlsClientConfig>();
    if (!alpnWire(alpn, cfg->alpnWire, err)) return nullptr;
    cfg->serverName = serverName;
    cfg->ipLiteral = isIpLiteral(serverName);
    cfg->verify = mode != 2;
    switch (mode) {
    case 1:
        cfg->ctx = makeTrustedContext(pem, err);
        break;
    case 2: {
        std::lock_guard<std::mutex> lk(cacheMutex());
        if (!cachedNoVerify()) cachedNoVerify() = makeNoVerifyContext(err);
        cfg->ctx = cachedNoVerify();
        break;
    }
    default: {
        // Built once per process (the store is read from disk); a failure
        // is not cached.
        std::lock_guard<std::mutex> lk(cacheMutex());
        if (!cachedSystem()) cachedSystem() = makeSystemContext(err);
        cfg->ctx = cachedSystem();
        break;
    }
    }
    if (!cfg->ctx) return nullptr;
    return cfg;
}

std::shared_ptr<TlsServerConfig> buildTlsServerConfig(const std::string& certificateChain,
                                                      const std::string& privateKey,
                                                      const std::vector<std::string>& alpn,
                                                      TlsError& err, TlsServerMode mode) {
    ERR_clear_error();
    auto cfg = std::make_shared<TlsServerConfig>();
    if (!alpnWire(alpn, cfg->alpnWire, err)) return nullptr;
    cfg->alpnNoAck = mode.alpnNoAck;
    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        err = tlsTakeError("SSL_CTX_new");
        return nullptr;
    }
    cfg->ctx = own(ctx);
    commonOptions(ctx);
    if (mode.h2Ciphers && SSL_CTX_set_cipher_list(ctx, kH2Tls12Ciphers) != 1) {
        err = tlsTakeError("ciphers");
        return nullptr;
    }
    (void)SSL_CTX_set_num_tickets(ctx, 0);   // no session resumption in v1 (TlsContext.hpp)

    // The chain: the leaf certificate first, then the intermediates.
    BIO* bio = BIO_new_mem_buf(certificateChain.data(), static_cast<int>(certificateChain.size()));
    if (!bio) {
        err = tlsTakeError("certificateChain");
        return nullptr;
    }
    X509* leaf = PEM_read_bio_X509_AUX(bio, nullptr, nullptr, nullptr);
    if (!leaf) {
        BIO_free(bio);
        err = tlsTakeError("certificateChain");
        return nullptr;
    }
    int ok = SSL_CTX_use_certificate(ctx, leaf);
    X509_free(leaf);
    if (ok != 1) {
        BIO_free(bio);
        err = tlsTakeError("certificateChain");
        return nullptr;
    }
    for (;;) {
        X509* ca = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
        if (!ca) break;
        if (SSL_CTX_add0_chain_cert(ctx, ca) != 1) {   // takes ownership on success
            X509_free(ca);
            BIO_free(bio);
            err = tlsTakeError("certificateChain");
            return nullptr;
        }
    }
    BIO_free(bio);
    ERR_clear_error();   // the loop ends on a "no start line" error

    BIO* kbio = BIO_new_mem_buf(privateKey.data(), static_cast<int>(privateKey.size()));
    if (!kbio) {
        err = tlsTakeError("privateKey");
        return nullptr;
    }
    EVP_PKEY* key = PEM_read_bio_PrivateKey(kbio, nullptr, nullptr, nullptr);
    BIO_free(kbio);
    if (!key) {
        err = tlsTakeError("privateKey");
        return nullptr;
    }
    ok = SSL_CTX_use_PrivateKey(ctx, key);
    EVP_PKEY_free(key);
    if (ok != 1 || SSL_CTX_check_private_key(ctx) != 1) {
        err = tlsTakeError("privateKey");
        return nullptr;
    }
    if (!cfg->alpnWire.empty()) SSL_CTX_set_alpn_select_cb(ctx, &alpnSelect, cfg.get());
    return cfg;
}

} // namespace Eco::System

#else // _WIN32: no OpenSSL (the kernels fail ENOTSUP before reaching here, §1)

namespace Eco::System {

void ensureTlsInit() {}

} // namespace Eco::System

#endif
