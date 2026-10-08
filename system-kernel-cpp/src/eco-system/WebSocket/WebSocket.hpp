//===- WebSocket.hpp - eco/system kernel module WebSocket (internal) ------===//
//
// plans/eco-system-websockets.md §3.6 and Appendix B.1: the binding bodies of
// Eco.Kernel.WebSocket (WebSocket.cpp), bound by WebSocketExports.cpp. The
// "WebSocket" effect manager (onMessage, onClose) is WsManager.{hpp,cpp}.
//
// Phases WS4 (Whole mode), WS6 (streamed messages), WS7 (permessage-deflate):
//   * handshakeKey (S), acceptFor (pure): WsHandshake.cpp.
//   * dial (P then R): wss builds the TLS client context on the SysWorkPool
//     first (stage 1, as Tls.connect), then a DialJob tries the addresses in
//     order under one deadline, writes the request and reads the response
//     head (WsHandshake.hpp); kill aborts. WS9: with `http2 = True` (wss)
//     ALPN offers h2 first and an h2 server gets an extended CONNECT
//     (Http2Client.hpp; isH2 = True), else HTTP/1.1.
//   * readUpgrade (R): takes a Socket.Connection over from its stream faces
//     (EBUSY while a face has an operation in flight; the faces' later
//     operations fail Cancelled "upgraded to WebSocket"; the bytes they had
//     read go to the handshake) and reads the request head.
//   * open (R): consumes a handshake id; writes the 101 (server), installs
//     the codec (WsProtocol) with the bytes read past the head, and creates
//     the mapped readable / writable over the WsChannel faces; mode 2 is
//     the streamed mode (WS6), a threshold >= 0 turns permessage-deflate on
//     with the negotiated parameters (WS7).
//     WS9: an h2 handshake (client: the Http2ClientProtocol holding the
//     answered stream; server: Http.Server's H2PendingUpgrade) is bound to
//     the codec through an H2StreamPort instead (H2StreamPort.hpp).
//   * reject (R), abandon (S): answer / drop a handshake id (h2 server: an
//     ordinary response / RST_STREAM(CANCEL)).
//   * close (R), closed (A), ping (R): WsCore operations.
//   * openOutgoing (S, WS6): an outgoing message stream's writable (a text
//     or binary channel sink over a WsOutChannel).
//
// Windows: no OpenSSL and no reactor: every fallible kernel fails ENOTSUP,
// the Task Never kernels complete at once (§1).
//
// Templates used: T1 (S bodies), T2 (dial stage 1), T7 (kill handles),
// T9/G10 (R and A bodies).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_WEBSOCKET_WEBSOCKET_HPP
#define ECO_SYSTEM_WEBSOCKET_WEBSOCKET_HPP

#include "eco-system/Core/Core.hpp"

#include <string>

namespace Eco::System {

// --- Kernel bodies (Appendix B.1) -------------------------------------------------

HPointer wsNotImplementedBody(HPointer captured);   // FErr ( "ENOTSUP", ... )
HPointer wsHandshakeKeyBody(HPointer captured);     // S: Task Never ( String, String )
HPointer wsDialBody(HPointer captured, HPointer resume);          // P then R
HPointer wsReadUpgradeBody(HPointer captured, HPointer resume);   // R
HPointer wsOpenBody(HPointer captured, HPointer resume);          // R
HPointer wsRejectBody(HPointer captured, HPointer resume);        // R (Task Never)
HPointer wsAbandonBody(HPointer captured);                        // S (Task Never)
HPointer wsCloseBody(HPointer captured, HPointer resume);         // R (Task Never)
HPointer wsClosedBody(HPointer captured, HPointer resume);        // A (Task Never)
HPointer wsPingBody(HPointer captured, HPointer resume);          // R
HPointer wsOpenOutgoingBody(HPointer captured);                   // S (WS6)

} // namespace Eco::System

#endif // ECO_SYSTEM_WEBSOCKET_WEBSOCKET_HPP
