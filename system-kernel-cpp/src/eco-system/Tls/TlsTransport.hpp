//===- TlsTransport.hpp - The TLS Transport of a connection ---------------===//
//
// A connection that speaks TLS needs something between its socket and its protocol that encrypts what is written and
// decrypts what is read. This component is that layer: the `Transport` (see `Conn.hpp`) a `Conn` uses for TLS.
//
// One OpenSSL `SSL` object holds the session. It is given two memory BIOs, OpenSSL's in-memory byte queues, instead
// of the socket: ciphertext received from the peer is written into the *read BIO*, and ciphertext OpenSSL produces is
// taken from the *write BIO*. The transport moves the bytes between the BIOs and the socket itself, with `recv`, and
// with `send` passing `kSendFlags`, so OpenSSL never touches the fd. The transport does not own the fd.
//
// Most of the transport follows from that arrangement. Any call into OpenSSL may produce output (handshake messages,
// alerts, a close_notify, an answer to a key update), so the handshake, reads, writes and `flush` first send what
// was produced and leave what the socket did not take as *pending output*, which `hasPendingWrite` reports and
// `flush` sends. When OpenSSL needs input, the transport reads one chunk from the socket into the read BIO and
// retries, until OpenSSL has what it needs or the socket would block.
//
//   * The handshake sends each *flight* (the messages one handshake step produces) before waiting for the peer, and
//     reports completion only once the final flight is on the socket.
//   * A write takes at most 64 KiB of plaintext per call, and only once earlier output has been sent, so the
//     pending output stays bounded.
//   * Ending the write direction queues a close_notify (only after a completed handshake with no failure), then
//     shuts down the socket's write side once the pending output has been sent, unless the transport is or
//     becomes broken.
//   * A failed `send` makes the transport *broken*: what was queued is dropped and nothing more is sent.
//
// Failures are reported through `Transport::errCode` and `errMessage`. A client's failed certificate verification
// gives the code `tlsVerifyCode` returns, with a message naming the host or IP address for a name mismatch. An
// OpenSSL protocol error (`SSL_ERROR_SSL` with a queued error) gives the code `tlsErrorCode` returns. A failed
// handshake with neither gives ECONNRESET and the message "Client network socket disconnected before secure TLS
// connection was established" when no error was recorded before, and a later failure with neither gives
// ECONNRESET. A failed `recv`, `send` or `shutdown` gives the errno's name.
//
// A transport is called on the reactor thread, as `Conn` requires of its members; its destructor, which frees the
// `SSL` object, runs wherever its `Conn` is destroyed. OpenSSL's error queue is per thread, and `handshake`, `read`
// and `write` clear it before calling into OpenSSL. A working transport keeps the TLS configuration it was made from
// alive, which a server's ALPN select callback needs (see `TlsServerConfig`).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TLS_TLS_TRANSPORT_HPP
#define ECO_SYSTEM_TLS_TLS_TRANSPORT_HPP

#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Tls/TlsContext.hpp"

#include <memory>

namespace Eco::System {

/// Returns a factory that makes a client-side TLS transport over the connected fd it is given, using `cfg`.
///
/// When `cfg->serverName` is not empty and `cfg->ipLiteral` is false, the transport sends it as SNI (the server name
/// indication), and, when verifying, the peer's certificate must match it, with no partial wildcards. When
/// `cfg->ipLiteral` is true it sends no SNI, and, when verifying, the certificate must list that address. An empty
/// `cfg->serverName` sends no SNI and sets no name check. The client offers `cfg->alpnWire` when it is not empty.
///
/// The factory ignores its `isServer` argument. When the `SSL` object cannot be set up, the factory returns a
/// transport whose handshake fails at once with the first queued OpenSSL error, or `ERR_SSL_UNKNOWN` when none was
/// queued, so a TLS connection never falls back to plain bytes; it does not return null. On Windows this function
/// itself returns a null factory.
TransportFactory makeTlsClientFactory(std::shared_ptr<TlsClientConfig> cfg);
/// Returns a factory that makes a server-side TLS transport over the accepted fd it is given, using `cfg`. The
/// factory ignores its `isServer` argument and fails as `makeTlsClientFactory` describes. On Windows this function
/// itself returns a null factory.
TransportFactory makeTlsServerFactory(std::shared_ptr<TlsServerConfig> cfg);

} // namespace Eco::System

#endif // ECO_SYSTEM_TLS_TLS_TRANSPORT_HPP
