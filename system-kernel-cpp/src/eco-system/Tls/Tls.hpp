//===- Tls.hpp - eco/system kernel module Tls (internal) ------------------===//
//
// `Socket.Tls` opens TLS client connections and TLS listeners, and reports what a TLS handshake negotiated. This
// component holds the three binding bodies behind it, which `TlsExports.cpp` binds to the kernel exports.
//
// A TLS connection is a TCP connection whose bytes pass through a TLS transport, so the bodies reuse the plain
// socket machinery (`socketStartConnect`, `tcpListenOn`, `completeListen`) and add only two things: an OpenSSL
// configuration, built by `TlsContext`, and a transport factory over it, made by `TlsTransport`. Building a
// configuration may read certificate files and so may block, which the eco thread (the thread that runs the Elm
// scheduler) must not do. It is therefore built on a `SysWorkPool` worker, and the socket work starts only once it
// is ready.
//
// A connect therefore runs in two steps under one resume token. A pool job builds the client configuration; its
// hand-off, on the eco thread, starts the connect with the TLS client factory under the same token
// (`socketContinueConnect`), so the Task is not resumed in between. Killing the Task while the job is queued cancels it
// (`SysWorkPool::cancel`); while it runs, the kill is recorded and the hand-off starts nothing; once the connect has
// started, it cancels the connect (`cancelPendingConnect`). A listen needs one step: a single pool job builds the server configuration and then
// opens the listening socket, and its completion records the listener in the shared listener table with the TLS
// server factory, so accepting and closing work as they do for a plain listener.
//
// On Windows there is no OpenSSL, and all three fail with the FErr code `ENOTSUP`.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TLS_TLS_HPP
#define ECO_SYSTEM_TLS_TLS_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

/// Connects over TLS to the address in `captured` and completes the Task with the connection, as
/// `socketStartConnect` describes, or with an FErr. `resume` is the Task's resume closure; the kill handle is
/// returned, or `()` on Windows, where the Task is resumed with an ENOTSUP failure before any work starts, and when
/// socket IO is unavailable (`socketIoAvailable`), where it is resumed with that failure.
///
/// `captured` is `tuple3( target, settings, tls )`, all boxed: `target` is `( String address, Int port, Int
/// timeoutMs )`, `settings` is `( Bool noDelay, Int keepAliveSec )`, and `tls` is `( String serverName, ( Int mode,
/// String pem ), List String alpn )`, with `mode` and `pem` as `buildTlsClientConfig` takes them. A negative timeout
/// is treated as 0, no limit; it covers the TCP connect and the handshake together. A configuration that cannot be
/// built fails the Task with its `TlsError` code, or `ERR_SSL_UNKNOWN` when that is empty.
HPointer tlsConnectBody(HPointer captured, HPointer resume);
/// Opens a TLS listener on the address in `captured` and completes the Task with it as `completeListen` describes,
/// or with an FErr. `resume` is the Task's resume closure; `()` is returned, as there is no kill handle.
///
/// `captured` is `tuple3( target, settings, tls )`, all boxed: `target` is `( String address, Int port )`,
/// `settings` is `( Int backlog, Bool ipv6Only )`, and `tls` is `( String certificateChain, String privateKey, List
/// String alpn )`, passed to `buildTlsServerConfig` and `tcpListenOn`. A configuration that cannot be built fails
/// the Task with its `TlsError` code, or `ERR_SSL_UNKNOWN` when that is empty, and no socket is opened. A socket
/// opened by a job whose result is never completed is closed when that result is destroyed.
HPointer tlsListenBody(HPointer captured, HPointer resume);
/// Returns a Task that succeeds with `( protocol, alpn, cipher )` of the TLS connection whose boxed Int id is
/// `captured`: the text of what its handshake negotiated, with `alpn` `Nothing` when no ALPN protocol was agreed.
/// It fails with `EINVAL` for an unknown id or a connection that is not TLS.
HPointer tlsInfoBody(HPointer captured);

#if ECO_TEST_HOOKS && !defined(_WIN32)
/// Test-only access to the connect's table of in-flight configuration jobs (TLS-10). Eco thread only.
namespace TlsTesting {
/// Returns the number of connects whose configuration job has not been drained or cancelled yet, for the current heap
/// generation.
size_t inflightConnectCount();
} // namespace TlsTesting
#endif

} // namespace Eco::System

#endif // ECO_SYSTEM_TLS_TLS_HPP
