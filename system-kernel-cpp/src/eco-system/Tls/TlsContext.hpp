//===- TlsContext.hpp - OpenSSL contexts for Socket.Tls -------------------===//
//
// plans/eco-system-sockets.md §3.6 "Contexts", "Init and exit", §D.5. An
// SSL_CTX holds the configuration shared by many connections; building one
// reads certificate files (the system CA store), so contexts are built on
// the SysWorkPool (T2), never on the reactor or the main thread.
//
//   * Client contexts, by verification mode:
//       0 SystemCertificates: SSL_CERT_FILE / SSL_CERT_DIR if set, else
//         SSL_CTX_set_default_verify_paths, and if the store is then empty
//         the first existing file of the §3.6 probe list. Built once and
//         cached process-wide (R3).
//       1 TrustedCertificates pem: a fresh store with only those
//         certificates (one or more PEM certificates; none → an error).
//       2 NoVerification: SSL_VERIFY_NONE (cached).
//     The per-connection parts (server name, ALPN offer) live in the
//     TlsClientConfig and are applied to each SSL by the transport factory
//     (TlsTransport.cpp): an IP-literal server name gets no SNI and an IP
//     SAN check (X509_VERIFY_PARAM_set1_ip_asc); a DNS name gets SNI and
//     SSL_set1_host.
//   * Server contexts: the certificate chain (leaf first) and private key
//     from PEM strings, and the ALPN list: the select callback picks the
//     first server protocol the client offers; no overlap → a fatal
//     no_application_protocol alert (Node's behaviour). Servers send no
//     TLS 1.3 session tickets (eco/system has no session resumption in v1,
//     and unread tickets would make a client's close send RST).
//   * Every context: TLS 1.2 minimum (Node's default), no renegotiation,
//     SSL_OP_IGNORE_UNEXPECTED_EOF (a FIN without close_notify is end of
//     input, as Node), partial writes and moving write buffers.
//   * Init and exit (N13): ensureTlsInit() (main thread, first TLS kernel
//     use) calls OPENSSL_init_ssl(OPENSSL_INIT_NO_ATEXIT) and registers
//     atexit(tlsQuiesce), which stops the IoReactor's dispatching (waiting
//     at most 100 ms), so no handler is inside OpenSSL while the process
//     exits. Atexit handlers run in reverse order: this runs before any
//     OpenSSL cleanup registered earlier (curl).
//
// Error mapping (§D.5), used here and by the transport:
//   * OpenSSL errors → "ERR_SSL_<REASON>": the reason string upper-cased,
//     spaces as '_' (e.g. ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL).
//   * X509 verification results → Node's names (tlsVerifyCode).
//
// Windows: no OpenSSL; nothing here is compiled except ensureTlsInit (a
// no-op). The kernels fail ENOTSUP first (Tls.cpp, §1).
//
// Templates used: T2 (worker side: POD only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TLS_TLS_CONTEXT_HPP
#define ECO_SYSTEM_TLS_TLS_CONTEXT_HPP

#include <memory>
#include <string>
#include <vector>

struct ssl_ctx_st;   // OpenSSL's SSL_CTX (no OpenSSL header here: Windows builds)

namespace Eco::System {

// Main thread, idempotent: OpenSSL init without its atexit cleanup, plus
// atexit(tlsQuiesce) (N13). Every TLS kernel body calls it first.
void ensureTlsInit();

struct TlsError {
    std::string code, message;
};

// A client connection's TLS configuration (immutable once built; shared by
// the connect's transport factory and its transport).
struct TlsClientConfig {
    std::shared_ptr<ssl_ctx_st> ctx;   // SSL_CTX (freed with SSL_CTX_free)
    std::string serverName;            // "" = no SNI, no name check
    bool verify = true;                // false: NoVerification
    bool ipLiteral = false;            // serverName is an IPv4/IPv6 address
    std::string alpnWire;              // ALPN offer, wire format ("" none)
};

// A listener's TLS configuration. The ALPN select callback's argument is this
// object, so it must outlive every SSL made from `ctx`: each transport holds
// a shared_ptr to it.
struct TlsServerConfig {
    std::shared_ptr<ssl_ctx_st> ctx;
    std::string alpnWire;              // server protocols, wire format ("" = ignore ALPN)
};

// SysWorkPool worker (blocking: CA files). `mode`: 0 system, 1 trusted
// `pem`, 2 none. Null with `err` set on failure (EINVAL for a bad ALPN
// list, ERR_SSL_* for unusable certificates).
std::shared_ptr<TlsClientConfig> buildTlsClientConfig(int64_t mode, const std::string& pem,
                                                      const std::string& serverName,
                                                      const std::vector<std::string>& alpn,
                                                      TlsError& err);

// SysWorkPool worker. Null with `err` set on failure.
std::shared_ptr<TlsServerConfig> buildTlsServerConfig(const std::string& certificateChain,
                                                      const std::string& privateKey,
                                                      const std::vector<std::string>& alpn,
                                                      TlsError& err);

// "ERR_SSL_<REASON>" for a packed OpenSSL error code (0 → "ERR_SSL_UNKNOWN"),
// and its message (ERR_error_string_n). Any thread.
std::string tlsErrorCode(unsigned long e);
std::string tlsErrorMessage(unsigned long e);

// §D.5: an X509_V_ERR_* verification result → Node's code
// (ERR_TLS_CERT_ALTNAME_INVALID for host/IP mismatches, CERT_VERIFY_FAILED
// for anything unlisted). Any thread.
std::string tlsVerifyCode(long verifyResult);

// The first OpenSSL error of this thread's queue as (code, message) for a
// context-building step `what`, then clears the queue.
TlsError tlsTakeError(const char* what);

} // namespace Eco::System

#endif // ECO_SYSTEM_TLS_TLS_CONTEXT_HPP
