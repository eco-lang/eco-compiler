//===- Tls.hpp - eco/system kernel module Tls (internal) ------------------===//
//
// plans/eco-system-sockets.md §3.6, Appendix B.3: the binding bodies of
// Eco.Kernel.Tls (Tls.cpp; bound by TlsExports.cpp).
//
//   * connect (P then R): the client context is built on the SysWorkPool
//     (TlsContext, the system context cached); its completion returns a
//     second binding (stage 2) that starts the connect exactly as
//     tcpConnect does (socketStartConnect) with the TLS transport factory.
//     The connect timeout covers the TCP connect and the handshake. Kill:
//     stage 1 cancels the pool job (T7, SysWorkPool::cancel); stage 2 has
//     the connect's kill handle (cancelPendingConnect).
//   * listen (P): one pool job builds the server context and then listens
//     (tcpListenOn); the completion hands the fd to completeListen with the
//     TLS factory, so the listener lives in the shared listener table
//     (Socket.accept / onConnection / closeListener work unchanged).
//   * info (S): from the ConnEntry (captured at handshake end); a non-TLS
//     (or unknown) connection fails EINVAL.
//
// Windows: connect / listen / info fail ENOTSUP (§1); no OpenSSL.
//
// Templates used: T1 (info), T2 (pool bodies + completions), T7 (kill
// handles), G10.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_TLS_TLS_HPP
#define ECO_SYSTEM_TLS_TLS_HPP

#include "eco-system/Core/Core.hpp"

namespace Eco::System {

HPointer tlsConnectBody(HPointer captured, HPointer resume);   // P then R
HPointer tlsListenBody(HPointer captured, HPointer resume);    // P
HPointer tlsInfoBody(HPointer captured);                       // S

} // namespace Eco::System

#endif // ECO_SYSTEM_TLS_TLS_HPP
