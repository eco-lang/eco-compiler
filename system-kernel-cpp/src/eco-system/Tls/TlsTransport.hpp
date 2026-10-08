//===- TlsTransport.hpp - The TLS Transport of a connection ---------------===//
//
// plans/eco-system-sockets.md §3.6 "Transport", §3.3.3 (Transport), N6, N7.
// A TlsTransport is a Conn's byte layer for TLS: one SSL over two MEMORY
// BIOs. The transport itself moves the bytes between the socket and the
// BIOs (recv, and send with MSG_NOSIGNAL), so OpenSSL never writes to the
// socket (no SIGPIPE in embed mode, SF10).
//
//   * handshake(): SSL_do_handshake until done; the output of each step is
//     sent before waiting for input, so exactly one of wantRead/wantWrite is
//     set when it returns 1, and it returns 0 only once the final flight is
//     on the socket. A failure sends what OpenSSL queued (an alert) best
//     effort and sets errCode per §D.5: a client's rejected certificate →
//     Node's verification code (CERT_HAS_EXPIRED, ERR_TLS_CERT_ALTNAME_INVALID,
//     …), a protocol error → ERR_SSL_<REASON>, a peer that went away →
//     ECONNRESET.
//   * read(): SSL_read; when OpenSSL needs input, one recv into the read
//     BIO (bounded: only on demand); a peer's FIN without close_notify is
//     end of input (SSL_OP_IGNORE_UNEXPECTED_EOF); socket errors keep their
//     errno name ("read ECONNRESET").
//   * write(): at most 64 KiB of plaintext per call goes into SSL_write once
//     the previous records are on the socket; records the socket does not
//     take at once stay pending (hasPendingWrite) and the Conn flushes them
//     when writable.
//   * shutdownWrite(): close_notify (SSL_shutdown), then SHUT_WR once it is
//     on the socket: 1 while that needs writability (the Conn keeps driving
//     it through hasPendingWrite/flush, also after a write-face shutdown).
//     Socket.close / reset never call it (no close_notify, as Node's
//     destroy()).
//   * info(): protocol (SSL_get_version), ALPN, cipher (OpenSSL name), read
//     by the Conn when the handshake ends.
//
// Reactor thread only (G1). The transport holds the TLS configuration
// (shared_ptr) so the server's ALPN callback argument outlives its SSL.
//
// Templates used: none (POD and OpenSSL only, G1).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TLS_TLS_TRANSPORT_HPP
#define ECO_SYSTEM_TLS_TLS_TRANSPORT_HPP

#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Tls/TlsContext.hpp"

#include <memory>

namespace Eco::System {

// Transport factories for Conn (clients, socketStartConnect) and
// ListenerHandler (accepted connections, completeListen). They never return
// null: a TLS object that cannot be created yields a transport whose
// handshake fails (so a TLS connection never silently falls back to plain).
TransportFactory makeTlsClientFactory(std::shared_ptr<TlsClientConfig> cfg);
TransportFactory makeTlsServerFactory(std::shared_ptr<TlsServerConfig> cfg);

} // namespace Eco::System

#endif // ECO_SYSTEM_TLS_TLS_TRANSPORT_HPP
