//===- SocketUtil.hpp - Small POSIX socket helpers shared by eco/system ---===//
//
// Socket code in eco/system creates sockets, accepts connections and converts
// between socket addresses and the text and port that Elm code works with.
// This component holds those POSIX helpers so that each piece of platform
// detail is written once. The functions touch no Elm heap and
// keep no state, so any thread may call them.
//
// Three facts shape the helpers.
//
//   * A descriptor must not leak into a child process, so the sockets made
//     here are made close-on-exec: atomically at creation where the platform
//     allows it (SOCK_CLOEXEC, accept4 on Linux) and with fcntl otherwise,
//     which leaves a window between creation and fcntl. On that fcntl path
//     `acceptCloexec` ignores a failure, so an accepted socket may lack it.
//   * Writing to a socket whose peer has gone raises SIGPIPE unless the write
//     says otherwise. Where MSG_NOSIGNAL exists, `kSendFlags` carries it and
//     socket writes are meant to pass it; where SO_NOSIGPIPE exists, the
//     sockets made here also get it.
//   * Addresses cross into Elm as text plus a port: dotted decimal for IPv4,
//     any IPv6 text inet_pton accepts, with an optional scope written
//     "%ifname" or "%index".
//
// Error convention: functions returning `int` return 0 or an errno value,
// except `socketCloexec` and `acceptCloexec`, which return a descriptor or
// -1. Functions returning `bool` report failure as false and leave their
// outputs untouched.
//
// On Windows the functions are stubs: the `int` ones fail with ENOTSUP
// (`setNoSigPipe` returns 0, `SockAddr::family` returns 0), the `bool` ones
// return false, `unixPathMax` is 0, `gaiCode` returns "EAI_FAIL", and
// `scopeName` prints the decimal id.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CORE_SOCKET_UTIL_HPP
#define ECO_SYSTEM_CORE_SOCKET_UTIL_HPP

#include <cstdint>
#include <string>

#ifndef _WIN32
#include <sys/socket.h>
#include <sys/types.h>
#else
struct sockaddr;
typedef int socklen_t;   // the same typedef as ws2tcpip.h
#endif

namespace Eco::System {

/// Returns the symbolic name of an errno value, such as "ECONNREFUSED".
/// Owned by ErrnoNames; redeclared here so that socket code need not include
/// the heap headers that Core.hpp brings in.
const char* errnoName(int err);

/// The flags to pass to send(), sendto() and sendmsg() on a socket:
/// MSG_NOSIGNAL where the platform defines it, otherwise 0.
#if !defined(_WIN32) && defined(MSG_NOSIGNAL)
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;
#endif

// --- fd flags ---------------------------------------------------------------

/// Sets FD_CLOEXEC on `fd`. Returns 0, or the errno from fcntl.
int setCloexec(int fd);
/// Sets O_NONBLOCK on `fd`. Returns 0, or the errno from fcntl.
int setNonBlocking(int fd);
/// Sets SO_NOSIGPIPE on `fd` where the platform defines it, returning 0 or the
/// errno from setsockopt. Elsewhere it does nothing and returns 0.
int setNoSigPipe(int fd);

/// Creates a socket as socket(2) does, close-on-exec, non-blocking when
/// `nonBlocking` is set, and with SO_NOSIGPIPE where that exists. Returns the
/// descriptor, or -1 with the errno in `*err` when `err` is non-null and in
/// errno. If a flag cannot be set the socket is closed and the call fails; a
/// failure to set SO_NOSIGPIPE is ignored.
int socketCloexec(int domain, int type, int protocol, bool nonBlocking, int* err);

/// Accepts a connection on `listenFd` as accept(2) does, close-on-exec,
/// non-blocking when `nonBlocking` is set, and with SO_NOSIGPIPE where that
/// exists. `addr` and `len` are passed to accept and may be null. Returns the
/// descriptor, or -1 with the errno in errno and also in `*err` when `err` is
/// non-null. EINTR is returned, not retried.
///
/// On Linux accept4 sets both flags atomically. Elsewhere they are set after
/// accept: a failure to set close-on-exec is ignored and the descriptor is
/// returned, a failure to set O_NONBLOCK closes it and fails the call.
int acceptCloexec(int listenFd, bool nonBlocking, struct sockaddr* addr, socklen_t* len,
                  int* err);

// --- addresses ----------------------------------------------------------------

/// A socket address of any family together with its length. Storage is
/// sockaddr_storage, zeroed on construction; `len` is 0 until an address has
/// been written, which is what makes it empty.
struct SockAddr {
#ifndef _WIN32
    struct sockaddr_storage ss;
#else
    alignas(8) unsigned char ss[128];
#endif
    socklen_t len = 0;

    /// Makes an empty address with `ss` zeroed.
    SockAddr();
    /// Returns a pointer to `ss`, valid while this SockAddr lives.
    struct sockaddr* get() { return reinterpret_cast<struct sockaddr*>(&ss); }
    /// Returns a pointer to `ss`, valid while this SockAddr lives.
    const struct sockaddr* get() const { return reinterpret_cast<const struct sockaddr*>(&ss); }
    /// Returns the stored address family, or AF_UNSPEC when `len` is 0.
    int family() const;
};

/// Writes to `out` the AF_INET or AF_INET6 address for `text` and `port`.
/// `text` is IPv4 dotted decimal, or IPv6 text with an optional scope after a
/// '%' that `parseScope` accepts. Returns 0, or EINVAL for a port outside
/// 0..65535, a NUL in `text`, text neither family accepts, a scope on an IPv4
/// address, or a scope `parseScope` rejects; `out` is untouched on failure.
int inetToSockaddr(const std::string& text, int64_t port, SockAddr& out);

/// Converts an AF_INET or AF_INET6 address to text and port. A non-zero IPv6
/// scope id is appended as '%' followed by `scopeName` of it. Returns false,
/// leaving the outputs untouched, when `sa` is null, of another family, or
/// `len` is shorter than that family's sockaddr.
bool sockaddrToInet(const struct sockaddr* sa, socklen_t len, std::string& text, int64_t& port);
/// Converts `sa` as the overload above does.
inline bool sockaddrToInet(const SockAddr& sa, std::string& text, int64_t& port) {
    return sockaddrToInet(sa.get(), sa.len, text, port);
}

/// Returns the text for an IPv6 scope id: the interface name, or the decimal
/// id when no interface name is found, or "" for 0.
std::string scopeName(uint32_t scopeId);
/// Parses scope text, without its '%', into a scope id: all digits is a
/// decimal index, anything else an interface name. Returns false, leaving
/// `scopeId` untouched, when `scope` is empty or longer than 15 characters, a
/// number is above 2^32-1, or no interface has the name.
bool parseScope(const std::string& scope, uint32_t& scopeId);

/// Writes to `out` the AF_UNIX address for `path`, its length covering the
/// path and a terminating NUL. Returns 0, or, checked in this order,
/// ENAMETOOLONG when the byte length is at least `unixPathMax()`, ENOENT for
/// an empty path, EINVAL for an embedded NUL; `out` is untouched on failure.
/// Unnamed and abstract addresses cannot be made.
int unixSockaddr(const std::string& path, SockAddr& out);
/// Returns sizeof(sockaddr_un::sun_path) on this platform (0 on Windows).
size_t unixPathMax();
/// Converts an AF_UNIX address to its path, read up to the first NUL or the
/// end of `len`. Unnamed and abstract addresses give "". Returns false,
/// leaving `path` untouched, when `sa` is null or of another family.
bool sockaddrToUnixPath(const struct sockaddr* sa, socklen_t len, std::string& path);

/// Rewrites an AF_INET address in place as the IPv4-mapped AF_INET6 address
/// ::ffff:a.b.c.d with the same port, so it can be used on an IPv6 socket.
/// Returns true if it converted; any other family is left unchanged.
bool mapIPv4ToIPv6(SockAddr& sa);

// --- name lookup --------------------------------------------------------------

/// Returns the error code string for a getaddrinfo failure: "ENOTFOUND" for
/// EAI_NONAME and EAI_NODATA, "EAI_AGAIN", "ENOMEM" for EAI_MEMORY,
/// `errnoName(sysErrno)` for EAI_SYSTEM, and "EAI_FAIL" for anything else.
/// `sysErrno` is read only for EAI_SYSTEM and should be errno as it was right
/// after getaddrinfo returned.
const char* gaiCode(int gaiErr, int sysErrno);

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SOCKET_UTIL_HPP
