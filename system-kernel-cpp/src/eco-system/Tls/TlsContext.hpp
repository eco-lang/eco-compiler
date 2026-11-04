//===- TlsContext.hpp - OpenSSL contexts for Socket.Tls -------------------===//
//
// A TLS connection needs an OpenSSL `SSL_CTX`: the configuration that many connections share, such as the trusted
// certificates or the server's certificate and key. Building one can read certificate files from disk, so this
// component builds contexts on a SysWorkPool worker, wraps each with the per-connection settings in a config record,
// and maps OpenSSL's errors to Node-style error codes.
//
// A client context is chosen by a verification *mode*, an integer:
//   * 0, SystemCertificates: peers are verified against the system's certificate authorities. If `SSL_CERT_FILE` or
//     `SSL_CERT_DIR` is set and non-empty, only those are tried; when both are set, a file that fails to load stops
//     the directory being added. Otherwise OpenSSL's default paths are loaded, and if that leaves the store empty,
//     the first existing file of a fixed list of common bundle paths. The context is built once and shared by
//     every client config in the process; a build that fails is not kept, and the next call tries again. Any mode
//     other than 1 or 2 is treated as 0.
//   * 1, TrustedCertificates: peers are verified against only the PEM certificates the caller gives. A new context
//     is built each time; no certificate in the text is an error.
//   * 2, NoVerification: the peer is not verified. The context is built once and shared, as for mode 0.
// The server name and ALPN offer are per connection, so they are kept in `TlsClientConfig`, not in the context.
//
// A server context holds the certificate chain (leaf first) and private key, read from PEM text, and the server's
// ALPN protocols. ALPN, application-layer protocol negotiation, lets the client offer protocol names (such as `h2`)
// in the handshake and the server pick one. In the *ALPN wire format* a list is a sequence of protocol names, each
// preceded by one byte holding its length, so each name is 1 to 255 bytes. The server picks the first protocol of
// its own list that the client offers; when there is none, the handshake fails with a fatal
// no_application_protocol alert, unless the *NoAck* fallback is set, in which case it completes without ALPN.
// Servers send no TLS 1.3 session tickets: eco/system has no session resumption, and unread tickets left in the
// client's receive buffer can make its close send a TCP reset.
//
// Every context requires TLS 1.2 or later, refuses renegotiation and compression, treats a TCP FIN without a TLS
// close_notify as the end of input where OpenSSL supports that option, and allows partial writes and a write buffer
// that moves between retries.
//
// OpenSSL is initialised by `ensureTlsInit` without OpenSSL's own exit cleanup. It instead registers `tlsQuiesce`
// with `std::atexit`, which asks the IoReactor to quiesce (see `IoReactor::quiesce`), waiting at most 100 ms, so that
// no new reactor handler, which may call into OpenSSL, starts while the process exits. Exit handlers run in reverse
// order of registration, so this one runs before any registered earlier.
//
// Error codes: an OpenSSL error becomes "ERR_SSL_" followed by its reason string, upper-cased with spaces as '_'
// (for example `ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL`); an X509 verification result becomes Node's name for
// it (`tlsVerifyCode`).
//
// On Windows there is no OpenSSL: only `ensureTlsInit` is defined, and it does nothing. The other functions are
// declared but not defined there.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TLS_TLS_CONTEXT_HPP
#define ECO_SYSTEM_TLS_TLS_CONTEXT_HPP

#include <memory>
#include <string>
#include <vector>

struct ssl_ctx_st;   // OpenSSL's SSL_CTX, declared here so the header builds without OpenSSL (Windows)

namespace Eco::System {

/// Initialises OpenSSL, without its own exit cleanup, creates the IoReactor, and registers `tlsQuiesce` to run at
/// exit. Only the first call does anything. It must be called on the eco thread: the flag that makes later calls
/// return at once is not synchronised.
void ensureTlsInit();

/// A failure to build a context: a Node-style `code` such as `ERR_SSL_...` or `EINVAL`, and a readable message.
struct TlsError {
    std::string code, message;
};

/// The TLS settings of one client connection: the shared context and the per-connection server name and ALPN offer.
/// This component does not change it after `buildTlsClientConfig` returns it; its members are public.
struct TlsClientConfig {
    std::shared_ptr<ssl_ctx_st> ctx;   ///< Freed with `SSL_CTX_free` when the last owner lets go.
    std::string serverName;            ///< The name to check the peer against; empty means none.
    bool verify = true;                ///< False for mode 2, NoVerification.
    bool ipLiteral = false;            ///< Whether `serverName` parses as an IPv4 or IPv6 address.
    std::string alpnWire;              ///< The ALPN offer in wire format; empty means no offer.
};

/// The TLS settings of a listener: the server context and its ALPN protocols.
///
/// When `alpnWire` is not empty, the context's ALPN select callback keeps a raw pointer to this object, so it must
/// outlive every connection made from `ctx`. Holding the `std::shared_ptr` that `buildTlsServerConfig` returns for as
/// long as such a connection exists keeps it alive.
struct TlsServerConfig {
    std::shared_ptr<ssl_ctx_st> ctx;
    std::string alpnWire;              ///< The server's protocols in wire format; empty means ALPN is not answered.
    bool alpnNoAck = false;            ///< Whether no common protocol completes without ALPN, not with an alert.
};

/// The options a server context may add to the default behaviour; a default-constructed value adds none.
struct TlsServerMode {
    /// Whether, when the client offers none of the server's protocols, the handshake completes without ALPN
    /// instead of failing with a fatal no_application_protocol alert.
    bool alpnNoAck = false;
    /// Whether TLS 1.2 cipher suites are restricted to ECDHE key exchange with AEAD ciphers, as HTTP/2 requires.
    /// TLS 1.3 suites are unaffected.
    bool h2Ciphers = false;
};

/// Builds the TLS settings for a client connection to `serverName` that offers the protocols `alpn`, verified as the
/// verification mode `mode` says (see the file comment); `pem` is read only for mode 1.
///
/// On failure it returns null and sets `err`: `EINVAL` for an ALPN name that is empty or longer than 255 bytes, and
/// an `ERR_SSL_...` code for a context that cannot be built, including mode 1 with no usable certificate. It may block
/// reading certificate files, so it is meant for a SysWorkPool worker. Calls from several threads are serialised on a
/// mutex while a shared context is looked up or built.
std::shared_ptr<TlsClientConfig> buildTlsClientConfig(int64_t mode, const std::string& pem,
                                                      const std::string& serverName,
                                                      const std::vector<std::string>& alpn,
                                                      TlsError& err);

/// Builds the TLS settings for a listener from the PEM text `certificateChain` (leaf certificate first, then any
/// intermediates) and `privateKey`, answering ALPN with the protocols `alpn`, with the options `mode` adds.
///
/// On failure it returns null and sets `err`: `EINVAL` for an ALPN name that is empty or longer than 255 bytes, or an
/// `ERR_SSL_...` code whose message names the step that failed (`certificateChain`, `privateKey`, `ciphers`), including
/// a key that does not match the leaf. It does no file IO.
std::shared_ptr<TlsServerConfig> buildTlsServerConfig(const std::string& certificateChain,
                                                      const std::string& privateKey,
                                                      const std::vector<std::string>& alpn,
                                                      TlsError& err,
                                                      TlsServerMode mode = TlsServerMode());

/// Returns the code for the packed OpenSSL error `e`: "ERR_SSL_" followed by its reason string, upper-cased with
/// spaces as '_', or "ERR_SSL_UNKNOWN" for 0 or an error with no reason string.
std::string tlsErrorCode(unsigned long e);
/// Returns OpenSSL's one-line description of the packed error `e`, or "unknown TLS error" for 0.
std::string tlsErrorMessage(unsigned long e);

/// Returns Node's code for the `X509_V_ERR_*` verification result `verifyResult`, such as `CERT_HAS_EXPIRED`.
/// A host name or IP address mismatch gives `ERR_TLS_CERT_ALTNAME_INVALID`, and any result without a name of its own
/// gives `CERT_VERIFY_FAILED`.
std::string tlsVerifyCode(long verifyResult);

/// Returns the oldest error in this thread's OpenSSL error queue as a `TlsError` whose message begins with `what`,
/// and empties the queue. An empty queue gives `ERR_SSL_UNKNOWN`.
TlsError tlsTakeError(const char* what);

} // namespace Eco::System

#endif // ECO_SYSTEM_TLS_TLS_CONTEXT_HPP
