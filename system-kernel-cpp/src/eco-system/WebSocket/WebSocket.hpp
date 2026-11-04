//===- WebSocket.hpp - eco/system kernel module WebSocket (internal) ------===//
//
// Elm's WebSocket module reaches the network through the `Eco.Kernel.WebSocket` kernels, and this component is the
// eco-thread half of those kernels: the Task binding bodies that read a kernel's arguments, act on the tables and
// objects of the other WebSocket components, and complete the Task. The C-linkage exports that build each body's
// payload and bind it are in WebSocketExports.cpp. `acceptFor` is pure and has no body here; its export returns
// `wsAcceptFor` of its argument directly.
//
// A body runs each time its Task runs, on the eco thread (the thread that runs the Elm scheduler). Two kinds exist.
// A synchronous body (`makeBinding`) returns the finished Task. An asynchronous body (`makeAsyncBinding`)
// parks its resume closure with the Scheduler under a token that also holds the program alive, hands work to the
// reactor thread (`IoReactor`) or the work pool (`SysWorkPool`), and returns a kill handle. The work later posts a
// `WsEvent`, and the dispatch functions `ensureWsTables` registers resume the Task and release the hold, as
// `WsTables` describes. A body that can settle without waiting (an unknown id, a bad argument) resumes its Task
// with the result before it returns.
//
// The kernels follow the life of a WebSocket through two kinds of id, both from `WsTables`:
//
//   * A handshake id names a connection whose opening HTTP exchange has been read but not answered. `dial` makes
//     one on the client side, `readUpgrade` on the server side from a `Socket.Connection`; Http.Server registers
//     others. `open`, `reject` and `abandon` each consume one.
//   * A WebSocket id names an open WebSocket, made by `open`. Its codec is a `WsCore`, and Elm reads and writes it
//     through a readable and a writable stream pair. `close`, `closed`, `ping` and `openOutgoing` act on it.
//
// A Task that can fail fails with an FErr `( code, message )`. Only `dial` and `closed` can be cancelled: killing
// either of them asks for the work to be withdrawn. The other asynchronous bodies return `()` as their kill handle,
// so killing their Task cancels nothing; when the result of a killed `readUpgrade` or `open` arrives, the dispatch
// function aborts the connection or WebSocket that nobody will now receive.
//
// On Windows the reactor never starts. `dial`, `readUpgrade` and `open` fail ENOTSUP and `reject` completes at
// once. The kernels that take a WebSocket id behave as for an unknown id: `close` completes, `closed` gives
// `( 1006, "", False )`, and `ping` and `openOutgoing` fail ECANCELED. `handshakeKey` gives two empty strings, as
// `wsNewKey` and `wsAcceptFor` return there.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WEBSOCKET_HPP
#define ECO_SYSTEM_WEBSOCKET_WEBSOCKET_HPP

#include "eco-system/Core/Core.hpp"

#include <string>

namespace Eco::System {

// --- Kernel bodies -----------------------------------------------------------------

/// Returns a Task that fails with ENOTSUP "not implemented yet", whatever `captured` is. No export in this module
/// binds it.
HPointer wsNotImplementedBody(HPointer captured);
/// Returns a Task that succeeds with `( key, accept )`: a fresh `Sec-WebSocket-Key` from `wsNewKey` and the
/// `Sec-WebSocket-Accept` value it calls for. `captured` is not read. The Task cannot fail; an exception from
/// `wsNewKey` is fatal.
HPointer wsHandshakeKeyBody(HPointer captured);
/// Dials a WebSocket server and reads its answer to the opening request.
///
/// `captured` is a 3-tuple of boxed fields: the target `( List String addresses, Int port, Int timeoutMs )`, the TLS
/// settings `( ( Bool tls, String serverName ), ( Int verification, String pem ), ( Bool http2, Bool ) )`, whose last
/// `Bool` is not read, and the request `( String target, List ( String, String ) headers )`. The Task succeeds with
/// `( handshakeId, ( status, isH2 ), headers )`, whatever the status, and fails as `DialJob` describes. With no
/// addresses it fails with ENOTFOUND at once.
///
/// The addresses are tried in order under one deadline of `timeoutMs`; 0 or less sets none. With `tls`, the TLS
/// client settings are first built on the work pool, which fails the Task with the `TlsError` code, or
/// ERR_SSL_UNKNOWN when there is none; the deadline starts only after that. `http2` is honoured only with `tls`:
/// ALPN then offers h2 first, and a server that chooses it is sent an extended CONNECT whose fields come from the
/// request headers, with Host becoming `:authority`, names lower-cased, and Upgrade, Connection,
/// `Sec-WebSocket-Key`, the other connection-specific fields and any header that fails `httpHeaderValid` left out.
/// `verification` is 0 for the system's certificates, 1 for those in `pem` and 2 for none. Killing the Task cancels
/// the dial.
HPointer wsDialBody(HPointer captured, HPointer resume);
/// Takes over the `Socket.Connection` with id `connId` and reads an opening request from it within `timeoutMs`.
///
/// `captured` is the 2-tuple `( Int connId, Int timeoutMs )`. The Task succeeds with
/// `( handshakeId, ( method, target, version ), ( headers, False, remote ) )`, and fails with ECANCELED
/// "socket closed" if the connection is unknown or no longer open, or with EBUSY if it has been taken over already
/// or one of its stream faces has a read, write or close in progress. Once taken, the faces' later operations fail
/// as cancelled with the reason "upgraded to WebSocket", and the bytes they had read ahead belong to the request.
/// How the head is read, and how it fails, is `UpgradeReadProtocol`'s contract.
HPointer wsReadUpgradeBody(HPointer captured, HPointer resume);
/// Opens a WebSocket on handshake `id`, consuming the handshake.
///
/// `captured` is a 3-tuple of boxed fields: `( Int id, ( Int status, List ( String, String ) headers ) )`, the
/// parameters `( ( role, mode, maxMessage ), ( heartbeatInterval, heartbeatTimeout, closeTimeout ),
/// ( threshold, ( ourNoContext, ourBits ), ( peerNoContext, peerBits ) ) )` and `( fromWire, toWire )`. Role 1 is
/// a server, which first answers an HTTP/1.1 handshake with `status` and `headers`. A server handshake on an HTTP/2
/// stream is answered on that stream whatever the role. Otherwise no answer is sent. Mode 1 delivers whole messages
/// and mode 2 streams them (`WsConfig::streamed`). A `threshold` of 0 or more turns permessage-deflate on with the
/// given parameters; window bits outside 8 to 15 become 15. A non-positive heartbeat interval or timeout becomes 0,
/// and a non-positive close timeout 30000 ms. `fromWire` and `toWire` are the closures the readable and writable
/// stream pairs map their values through, as `createMappedSource` and `createMappedSink` describe.
///
/// The Task succeeds with `( wsId, ( readableId, writableId ), ( local, remote ) )`. It fails with EINVAL if the
/// handshake id is unknown (answered already, or never made) or the mode is neither 1 nor 2, leaving the handshake
/// in place in the second case, and with ECONNRESET "socket closed" if the connection or stream has gone. A peer
/// hold registered with the handshake is released after this Task's own hold is taken.
HPointer wsOpenBody(HPointer captured, HPointer resume);
/// Answers handshake `id` with a refusal and consumes it.
///
/// `captured` is `( Int id, ( Int status, List ( String, String ) headers, String body ) )`. A status below 100 or
/// above 999 becomes 400. Over HTTP/1.1 the response is written and the connection closed gracefully; over an HTTP/2
/// stream it is an ordinary response on that stream. The Task completes once the response is written or the
/// write has failed, and without writing anything for an unknown id or a connection or stream no longer open. A
/// peer hold registered with the handshake is released after this Task's own hold is taken.
HPointer wsRejectBody(HPointer captured, HPointer resume);
/// Drops handshake `id` without answering it: aborts its connection, or abandons its HTTP/2 stream, and releases any
/// peer hold registered with it. `captured` is the boxed Int `id`. Does nothing for an unknown id. The Task completes
/// at once.
HPointer wsAbandonBody(HPointer captured);
/// Starts the closing handshake of WebSocket `wsId` with `code` and `reason`, as `WsCore::startClose` describes, and
/// takes the close-handshake hold (`wsTablesCloseStarted`).
///
/// `captured` is `( Int wsId, Int code, String reason )`. The Task completes when `WsCore::startClose` reports, or
/// at once if the WebSocket is unknown or has ended.
HPointer wsCloseBody(HPointer captured, HPointer resume);
/// Waits for WebSocket `wsId` to end and gives its `( code, reason, clean )`. `captured` is the boxed Int `wsId`.
///
/// For a WebSocket that has ended the Task completes at once, from its entry or, once the entry is erased, from the
/// recently closed list; an id in neither gives `( 1006, "", False )`. Killing the Task withdraws the wait.
HPointer wsClosedBody(HPointer captured, HPointer resume);
/// Pings WebSocket `wsId` and succeeds with the round-trip time in milliseconds, as `WsCore::startPing` describes.
/// `captured` is the boxed Int `wsId`. Fails with ECANCELED at once if the WebSocket is unknown or has ended.
HPointer wsPingBody(HPointer captured, HPointer resume);
/// Opens one outgoing message of WebSocket `wsId`, to be sent in pieces, and succeeds with the id of the writable
/// stream pair it is written through.
///
/// `captured` is `( Int wsId, Int kind )`. Kind 1 is a text message, written as Strings; any other kind is binary,
/// written as Bytes. The message takes its place in the WebSocket's outgoing queue
/// as `WsCore::openOutgoing` describes. Fails with ECANCELED if the WebSocket is unknown or has ended.
HPointer wsOpenOutgoingBody(HPointer captured);

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WEBSOCKET_HPP
