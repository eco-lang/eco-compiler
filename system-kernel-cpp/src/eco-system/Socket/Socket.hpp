//===- Socket.hpp - eco/system kernel module Socket (internal) ------------===//
//
// Elm code opens stream sockets and resolves host names through the kernels of `Eco.Kernel.Socket`, and this
// component is what those kernels do when their Tasks run. It also supplies the connect and listen steps that the
// Tls component reuses with a TLS transport.
//
// Each kernel export (SocketExports.cpp) passes its body one heap value, the *payload*, and returns a Task binding
// over it. The binding's body, declared here, runs each time the Task runs. A body completes its Task in one
// of four ways, named by a letter in the comments below:
//
//   * S (sync): the body returns the finished Task.
//   * P (pool): the body parks the Task's resume closure, which takes a hold, and runs the blocking part on a
//     `SysWorkPool` worker; the result is turned into the Task's outcome on the eco thread.
//   * R (reactor): the body parks the resume closure, which takes a hold, submits the work to the IO reactor, and
//     the Task is completed when the matching `SocketEvent` is dispatched by `SocketTables`.
//   * A (accept): the body parks the resume closure on a listener's table entry until a connection is delivered.
//
// The connections and listeners themselves are `Conn` and `ListenerHandler` objects on the reactor thread. Elm code
// names them by integer ids, which the tables of `SocketTables` map to their entries on the eco thread.
//
// A listen is split in two because its system calls block. `tcpListenOn` or `unixListenOn` runs on a worker and
// produces a `ListenResult`, which owns the new socket. `completeListen` then runs on the eco thread and hands the
// socket to a new `ListenerHandler`. If the task is killed, the unused result closes its socket and removes any
// Unix socket file it created when it is destroyed; a listen that fails does the same before it returns.
//
// On Windows nothing here opens a socket. Connect and listen fail with ENOTSUP, as does lookup of a non-empty name;
// the kernels that take an id find no entry and behave as they do for an unknown id.
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

// --- Building blocks (eco thread unless noted) ---------------------------------

/// Returns whether socket IO is available: the IO reactor started (`IoReactor::ok`). When it did not, nothing a
/// socket kernel submits would ever run, so a kernel checks this before it parks a Task and fails instead with
/// `socketIoUnavailable`. Creates the reactor on the first call. May be called from any thread.
bool socketIoAvailable();

/// Returns the FErr Task `( "ENOSYS", "<op> ENOSYS socket IO unavailable: ..." )` of a socket kernel named `op` run
/// while `socketIoAvailable` is false. Allocates.
HPointer socketIoUnavailable(const char* op);

/// Starts a client connect to `spec` over a transport built by `factory` (null for the plain transport), and returns
/// the Task's kill handle. R mode.
///
/// It must be called from a `makeAsyncBinding` body inside `ECO_SYSTEM_ASYNC_GUARD`, with that guard's `resume`,
/// `token` and `counted`. Without socket IO (`socketIoAvailable`) it completes the Task at once with
/// `socketIoUnavailable` and returns `()`. Otherwise it parks `resume`, taking a hold, and at once sets `token` to the
/// resume token and `counted` to true, so that the guard can release them if a later step throws; it makes the kill
/// handle before the connect is registered or submitted, so that a throw leaves nothing behind for the guard but the
/// hold. The Task is completed when the connect's `Connected` event is dispatched by `SocketTables`, with the new
/// connection or the connect's FErr. Killing the Task runs `cancelPendingConnect`.
HPointer socketStartConnect(ConnectSpec spec, TransportFactory factory, HPointer& resume,
                            uint64_t& token, bool& counted);

/// Starts a client connect to `spec` over a transport built by `factory`, for a Task whose resume is already parked
/// under `token`, with its hold, as `socketStartConnect` does after parking. The connect's `Connected` event completes
/// the Task and releases the hold, and `cancelPendingConnect(token)` cancels it, so the caller's kill handle must run
/// that once this has returned. Throws, with nothing registered or submitted, if the connect cannot be started
/// (including when socket IO is unavailable); the resume and the hold then remain the caller's.
void socketContinueConnect(ConnectSpec spec, TransportFactory factory, uint64_t token);

/// The sole owner of a listening socket and of the Unix socket file it created.
///
/// When a `ListenFd` is reset or destroyed, it closes `fd` if it is not negative and removes the file at
/// `createdPath` if that is not empty (not on Windows). To hand the socket on without closing it, set `fd` to -1 and
/// clear `createdPath`, as `completeListen` does. A `ListenFd` can be moved but not copied. Moving hands both over,
/// and the moved-from object holds nothing. Nothing ties it to a thread.
struct ListenFd {
    int fd = -1;               ///< The owned descriptor, or -1 for none.
    std::string createdPath;   ///< The file to remove on reset, or empty for none.

    /// Creates a `ListenFd` that owns nothing.
    ListenFd() = default;
    /// Takes over what `o` owns, leaving `o` owning nothing.
    ListenFd(ListenFd&& o) noexcept;
    /// Releases what this object owns, as `reset` does, then takes over what `o` owns, leaving `o` owning nothing.
    /// Does nothing when `o` is this object.
    ListenFd& operator=(ListenFd&& o) noexcept;
    ListenFd(const ListenFd&) = delete;
    ListenFd& operator=(const ListenFd&) = delete;
    ~ListenFd();
    /// Closes the descriptor and removes the file, ignoring failures, and leaves the object owning nothing.
    void reset();
};

/// The outcome of the blocking part of a listen: the bound socket, or why there is none.
///
/// Made by `tcpListenOn` and `unixListenOn` and moved, not copied. A non-empty `code` means the listen
/// failed; `owned` then holds nothing, and `isUnix` and `bound` mean nothing.
struct ListenResult {
    ListenFd owned;
    bool isUnix = false;
    SockEndpoint bound;   ///< The address the socket is bound to.
    // On failure, the FErr: `code` is an errno name, and `message` is `listen`, the code and `what`.
    std::string code, message;
};

/// Opens a non-blocking TCP socket listening on `address` and `port`, and returns it in a `ListenResult`.
///
/// Blocks, and touches no Elm heap value, so it may run on a worker thread. The socket is close-on-exec, and
/// SO_REUSEADDR is asked for. For an IPv6 address IPV6_V6ONLY is asked to be `ipv6Only`; a failure of either request
/// is ignored.
/// `backlog` is clamped to 1..65535. `bound` holds the address and port reported by getsockname, so a `port` of 0
/// comes back as the port chosen; if getsockname or its conversion fails, `bound` holds `address` and `port`. A
/// failure is reported in the result, with `what` being `address:port`, whichever call failed.
ListenResult tcpListenOn(const std::string& address, int64_t port, int64_t backlog, bool ipv6Only);
/// Opens a non-blocking Unix domain socket listening at `path`, and returns it in a `ListenResult`.
///
/// Blocks, and touches no Elm heap value, so it may run on a worker thread. If something exists at `path`, the
/// listen fails with EADDRINUSE unless `removeExisting` is set and it is a socket, which is then removed. When
/// `mode` is not negative, the file's permissions are set to `mode & 07777` before `listen`, so no client can connect
/// before they are set. The backlog is 511. Once the socket is bound, the result owns the file, so a later failure
/// removes it. A failure is reported in the result, with `what` being `path`, whichever call failed.
ListenResult unixListenOn(const std::string& path, bool removeExisting, int64_t mode);

/// Finishes a listen on the eco thread: returns a Task failing with `r`'s FErr if `r` holds a failure, and
/// otherwise a Task succeeding with the new listener `( id, bound )`.
///
/// On success, the socket and file in `r` are handed to a new `ListenerHandler` built with `factory` (null for the
/// plain transport) and started on the reactor, and a `ListenerEntry` is recorded under a fresh listener id; `r` then
/// owns nothing. On failure `r` is not changed. An open listener takes no hold of its own: parked accepts and
/// subscriptions do. Nothing names the new id yet, so the listener accepts nothing until an accept or a subscription
/// asks it to.
HPointer completeListen(ListenResult& r, TransportFactory factory);

// --- Kernel bodies ---------------------------------------------------------------
//
// The binding bodies of the exports in SocketExports.cpp, which describes each payload. `captured` is the payload
// and `resume` the Task's resume closure. An async body returns the Task's kill handle, `()` where there is none.
// Each body is guarded: an exception fails the Task with an FErr whose code is EIO, except in `socketCloseBody` and
// `socketResetBody`, whose Tasks cannot fail, where it is fatal.

/// Resolves the host name in `captured` and completes the Task with its addresses as text, in the order the resolver
/// gave them, duplicates removed. P mode; killing the Task runs `SysWorkPool::cancel`.
///
/// Only IPv4 and IPv6 addresses are kept, and an IPv6 scope is written after a `%`. An empty name fails ENOTFOUND
/// without calling the resolver; a name that resolves to no address also fails ENOTFOUND. A resolver failure gives
/// the code `gaiCode` maps it to. Off Windows, the message is `"getaddrinfo <code> <name>"`.
HPointer socketLookupBody(HPointer captured, HPointer resume);
/// Connects to a TCP address and completes the Task with the connection, as `socketStartConnect` describes, over the
/// plain transport. A negative timeout is treated as 0, which is no limit. R mode.
HPointer socketTcpConnectBody(HPointer captured, HPointer resume);
/// Connects to the Unix socket at the path in `captured` and completes the Task with the connection, as
/// `socketStartConnect` describes, over the plain transport. R mode.
HPointer socketUnixConnectBody(HPointer captured, HPointer resume);
/// Listens on a TCP address with `tcpListenOn` and completes the Task through `completeListen`. P mode. There is no
/// kill handle; a result that is not used closes its socket when it is destroyed.
HPointer socketTcpListenBody(HPointer captured, HPointer resume);
/// Listens on a Unix socket path with `unixListenOn` and completes the Task through `completeListen`. P mode. There
/// is no kill handle; a result that is not used closes its socket and removes its file when it is destroyed.
HPointer socketUnixListenBody(HPointer captured, HPointer resume);
/// Accepts one connection on the listener whose id is `captured`, and completes the Task with it.
///
/// An unknown or closing listener fails the Task at once with ECANCELED. If the listener holds a connection that
/// has not been delivered, the oldest one completes the Task at once. Otherwise the Task is parked on the listener
/// (A mode), taking a hold, and the listener is given credit for one more connection; the Task is completed when
/// `SocketTables` delivers the next connection. Killing a parked Task runs `cancelParkedAccept`.
HPointer socketAcceptBody(HPointer captured, HPointer resume);
/// Closes the listener whose id is `captured`, and completes the Task when it has closed. R mode.
///
/// An unknown listener succeeds at once, so closing twice is harmless. Otherwise the Task is parked, taking a hold,
/// and is completed when the listener's `ListenerClosed` event is dispatched, after its socket is closed and its
/// Unix file removed. The first call on a listener marks it closing, aborts the connections it holds undelivered,
/// asks the listener to close, and fails its parked accepts with ECANCELED. Later calls only wait. There is no kill
/// handle.
HPointer socketCloseListenerBody(HPointer captured, HPointer resume);
/// Returns a Task succeeding with `()`, after asking the reactor to abort the connection whose id is `captured`, as
/// `Conn::abort` describes. An unknown id is ignored. The abort happens later, on the reactor thread. S mode.
HPointer socketCloseBody(HPointer captured);
/// Returns a Task succeeding with `()`, after asking the reactor to reset the connection whose id is `captured`: an
/// abort as `Conn::abort` describes, with reset set. An unknown id is ignored. The reset happens later, on the
/// reactor thread. S mode.
HPointer socketResetBody(HPointer captured);
/// Sets TCP_NODELAY on a connection as `Conn::setNoDelay` does, and completes the Task when it is done. R mode.
///
/// An unknown id, or a Unix connection, succeeds at once without doing anything. A failure gives the code of the
/// errno and the message `"setsockopt <code>"`. There is no kill handle.
HPointer socketSetNoDelayBody(HPointer captured, HPointer resume);
/// Sets TCP keep-alive on a connection as `Conn::setKeepAlive` does, and completes the Task when it is done. R mode.
///
/// An unknown id, or a Unix connection, succeeds at once without doing anything. A failure gives the code of the
/// errno and the message `"setsockopt <code>"`. There is no kill handle.
HPointer socketSetKeepAliveBody(HPointer captured, HPointer resume);
/// Returns a Task succeeding with the peer's `( pid, uid, gid )` for the Unix connection whose id is `captured`.
/// S mode.
///
/// An unknown id or a connection that is not Unix fails with EINVAL, and a Unix connection without credentials
/// fails with ENOTSUP.
HPointer socketPeerCredentialsBody(HPointer captured);

} // namespace Eco::System

#endif // ECO_SYSTEM_SOCKET_SOCKET_HPP
