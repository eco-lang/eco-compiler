//===- Socket.hpp - eco/system kernel module Socket (internal) ------------===//
//
// plans/eco-system-sockets.md §3.3, Appendix B.1. The binding bodies of the
// stream-socket kernels of Eco.Kernel.Socket (Socket.cpp; bound by
// SocketExports.cpp) and the building blocks EcoSystem_Tls (S5) reuses:
//
//   * socketStartConnect: the R-mode client connect over any transport
//     factory (tcpConnect / unixConnect use the plain transport; Tls.connect
//     passes its TLS factory after building its context on the pool).
//   * tcpListenOn / unixListenOn: the blocking part of a listen (socket,
//     options, bind, chmod, listen) for a SysWorkPool job; the ListenResult
//     owns the fd and the created Unix path through RAII (ListenFd), so a
//     killed task's orphaned result closes and unlinks them (N11).
//   * completeListen: the main-thread completion: hands the fd to a new
//     ListenerHandler (with the given transport factory), records the
//     ListenerEntry, takes the listener's pendingAsync count (§3.3.8) and
//     builds the ListenT.
//
// Modes (Appendix B): S sync binding; P SysWorkPool (T2); R reactor round
// trip (pendingAsync + submit + SocketEvent); A parked on a table entry.
// Windows: the fallible kernels fail ENOTSUP, close/reset do nothing (§1).
//
// Templates used: T1, T2, T7 (helpers declared here).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_SOCKET_SOCKET_HPP
#define ECO_SYSTEM_SOCKET_SOCKET_HPP

#include "eco-system/Core/Core.hpp"
#include "eco-system/Socket/Conn.hpp"
#include "eco-system/Socket/SocketEvents.hpp"

#include <cstdint>
#include <string>

namespace Eco::System {

// A Task that fails with ( "ENOTSUP", "not implemented yet" ) (FErr) when
// run (the Tls stubs until S5). Allocates; call it last in an export.
HPointer socketNotImplementedTask();

// A `Task Never ()` that succeeds with () when run, doing nothing.
HPointer socketDoneTask();

// --- Building blocks (main thread unless noted) --------------------------------

// R mode, inside a makeAsyncBinding body (under ECO_SYSTEM_ASYNC_GUARD):
// registers `resume` (token), takes the connect's pendingAsync count
// (counted), records the pending connect and submits the connect. Returns
// the T7 kill handle (kill → abort; an orphaned success is closed).
HPointer socketStartConnect(ConnectSpec spec, TransportFactory factory, HPointer& resume,
                            uint64_t& token, bool& counted);

// Owns a listening fd and the Unix socket path it created until release()
// (RAII, N11). Move-only; any thread.
struct ListenFd {
    int fd = -1;
    std::string createdPath;   // unlinked on destruction unless released

    ListenFd() = default;
    ListenFd(ListenFd&& o) noexcept;
    ListenFd& operator=(ListenFd&& o) noexcept;
    ListenFd(const ListenFd&) = delete;
    ListenFd& operator=(const ListenFd&) = delete;
    ~ListenFd();
    void reset();
};

struct ListenResult {
    ListenFd owned;
    bool isUnix = false;
    SockEndpoint bound;
    std::string code, message;   // failure (code non-empty)
};

// Pool worker (blocking; POD only, G1). §3.3.7.
ListenResult tcpListenOn(const std::string& address, int64_t port, int64_t backlog, bool ipv6Only);
ListenResult unixListenOn(const std::string& path, bool removeExisting, int64_t mode);

// Main thread (a T2 completion): FErr on failure, else the ListenT.
// `factory` null = plain transport.
HPointer completeListen(ListenResult& r, TransportFactory factory);

// --- Kernel bodies (Appendix B.1) ----------------------------------------------

HPointer socketLookupBody(HPointer captured, HPointer resume);            // P
HPointer socketTcpConnectBody(HPointer captured, HPointer resume);        // R
HPointer socketUnixConnectBody(HPointer captured, HPointer resume);       // R
HPointer socketTcpListenBody(HPointer captured, HPointer resume);         // P
HPointer socketUnixListenBody(HPointer captured, HPointer resume);        // P
HPointer socketAcceptBody(HPointer captured, HPointer resume);            // A
HPointer socketCloseListenerBody(HPointer captured, HPointer resume);     // R
HPointer socketCloseBody(HPointer captured);                              // S
HPointer socketResetBody(HPointer captured);                              // S
HPointer socketSetNoDelayBody(HPointer captured, HPointer resume);        // R
HPointer socketSetKeepAliveBody(HPointer captured, HPointer resume);      // R
HPointer socketPeerCredentialsBody(HPointer captured);                    // S

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_SOCKET_HPP
