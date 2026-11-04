//===- HttpServer.hpp - eco/system kernel module HttpServer (internal) ----===//
//
// The Elm module `Http.Server` starts servers, answers requests and closes servers through the kernel module
// `Eco.Kernel.HttpServer`. This header declares the binding bodies of those kernels: the functions a Task runs
// when it is performed. The C exports in HttpServerExports.cpp pack each kernel's arguments into one heap value,
// the captured payload, and bind it to a body declared here.
//
// The bodies run on the eco thread, the thread that runs the Elm scheduler. Each one first reads the payload,
// copying everything it needs into C++ values without allocating on the heap, because an allocation may move the
// payload. It then hands the work to plain C++ code that never touches the heap: a `SysWorkPool` job, the
// eco-thread tables of `HttpTables.hpp`, or the reactor behind them.
//
// The bodies come in two shapes. An asynchronous body takes the task's resume closure, parks it, and returns at
// once; the task completes when the work finishes, possibly at once. A synchronous body returns the Task itself.
// A failure is the FErr tuple `( code, message )`, `code` being an errno name or another short code.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP
#define ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

/// Starts a server listening on a host name and port, and completes with `( serverId, boundAddress, boundPort )`.
///
/// `captured` is the tuple `( host, port )`, with `port` an unboxed Int. An empty host means every local address,
/// and port 0 lets the system choose, the chosen port being `boundPort`. The host is resolved and the socket opened
/// on a `SysWorkPool` worker, and the server is then registered with `httpTablesStartServer`, with no connection
/// limit. A failure to listen completes the task with the FErr `HttpSrv::listenOn` reports; on Windows that is
/// always ENOTSUP. Killing the task does not cancel the job.
HPointer httpServerCreateServerBody(HPointer captured, HPointer resume);

/// Starts a server with explicit protocols, limits and, optionally, TLS, and completes as
/// `httpServerCreateServerBody` does.
///
/// `captured` is the tuple `( target, tls, limits )`:
///
/// - `target` is `( ( address, port ), ( protocols, maxConnections ) )`. `protocols` has bit 0 for HTTP/1.x and
///   bit 1 for HTTP/2; a negative `maxConnections` means no limit.
/// - `tls` is `Nothing`, or `Just ( certificateChain, privateKey )` in PEM text.
/// - `limits` is `( ( keepAliveMs, headersMs, requestMs ), ( maxBodySize, maxHeaderSize, maxConcurrentStreams ) )`,
///   copied into the server's `ServerConfig`.
///
/// It fails with EINVAL, without starting any work, when neither protocol is asked for or HTTP/2 is asked for
/// without TLS, and with ENOTSUP on Windows when TLS is asked for. With TLS, the worker builds the TLS context
/// before listening, and a failure there is reported with `buildTlsServerConfig`'s code. The server offers ALPN
/// `h2` with HTTP/2 and `http/1.1` with HTTP/1.x; with HTTP/1.x, a client offering neither is still served
/// HTTP/1.1, and with HTTP/2 the TLS 1.2 ciphers are restricted as HTTP/2 requires. The socket is opened with
/// `tcpListenOn`, so failures are reported as it describes. Killing the task does not cancel the job.
HPointer httpServerCreateServerWithBody(HPointer captured, HPointer resume);

/// Answers the request with response key `key`, and completes with `()` once the reactor has finished with the
/// response, whether or not it could be sent, or at once if the key is unknown, already answered, taken as an
/// upgrade or of an earlier heap.
///
/// `captured` is `( ( key, status ), ( headers, body ) )`, with `key` and `status` unboxed Ints, `headers` a
/// `List ( String, List String )` sent as one header line per value, and `body` a `Bytes`. What is done with the
/// response is as `HttpSrv::httpTablesRespond` describes. The task never fails, except by a fatal error.
HPointer httpServerRespondBody(HPointer captured, HPointer resume);

/// Answers like `httpServerRespondBody`, with the body written as the HTML text of an `Html.Dom` node.
///
/// `captured` is `( ( key, status ), ( headers, doctype, node ) )`. When `doctype` is `True`, the body starts with
/// `<!DOCTYPE html>`. The node is written after it with `Elm::Kernel::VirtualDom::writeHtml`.
HPointer httpServerRespondHtmlBody(HPointer captured, HPointer resume);

/// Closes the server `serverId`, and completes with `()` once it has finished closing, or at once if the server is
/// unknown, already closed or of an earlier heap.
///
/// `captured` is `( serverId, deadlineMs )`, both unboxed Ints. What closing does, and what `deadlineMs` means, is
/// as `HttpSrv::httpTablesCloseServer` describes. The task never fails, except by a fatal error.
HPointer httpServerCloseServerBody(HPointer captured, HPointer resume);

/// Takes over the upgrade request with response key `key` for a WebSocket handshake, and returns a Task that
/// succeeds with `( handshakeId, ( method, target, version ), ( headers, isH2, remote ) )`.
///
/// `captured` is the boxed Int `key`, and `remote` is the peer's endpoint as `( Int, String, Int )`. The Task
/// fails with EINVAL when the key is not a pending upgrade request, with ECANCELED when its connection has closed,
/// and with ENOTSUP on Windows. This body is defined in HttpUpgrade.cpp.
HPointer httpServerTakeUpgradeBody(HPointer captured);

} // namespace Eco::System

#endif // ECO_SYSTEM_HTTP_SERVER_HTTP_SERVER_HPP
