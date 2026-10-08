//===- SocketUtil.hpp - Small POSIX socket helpers shared by eco/system ---===//
//
// plans/eco-system-sockets.md §4 S2 step 2 (used by Http.Server today and by
// Socket/Tls from S3 on). Pure helpers: no threads, no heap access (G1), safe
// on any thread.
//
//   * fd flags: setCloexec / setNonBlocking / setNoSigPipe, socketCloexec
//     (SOCK_CLOEXEC where it exists) and acceptCloexec (accept4 on Linux;
//     accept + fcntl + SO_NOSIGPIPE elsewhere, race-free on macOS because
//     children are spawned with POSIX_SPAWN_CLOEXEC_DEFAULT, sockets SF9).
//   * kSendFlags: MSG_NOSIGNAL where it exists. SIGPIPE is NOT ignored in
//     embed mode (SF10), so every send() on a socket uses it; where it does
//     not exist (macOS) every socket gets SO_NOSIGPIPE instead.
//   * sockaddr <-> (text, port): IPv4 dotted decimal, IPv6 RFC 4291 text (any
//     form inet_pton accepts) with an optional scope: printed "%ifname"
//     (if_indextoname, falling back to the decimal index), parsed from
//     "%ifname" or "%index". Elm parses the text again and prints it
//     canonically (§D.1, SD13), so the exact form printed here is free.
//   * Unix sockaddr from a path with the §D.3 length check.
//   * IPv4 -> IPv4-mapped IPv6 (§D.4: IPv4 destinations on IPv6 sockets).
//   * gaiCode: getaddrinfo error -> FErr code (§3.3.6).
//
// Error convention: functions returning `int` return 0 or an errno value
// (never -1); errno itself is not relied upon by callers.
//
// Windows: the fd helpers and conversions fail with ENOTSUP (§1).
//
// Templates used: none (POD only, G1).
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

// errno -> "ECONNREFUSED" etc. Defined in ErrnoNames.cpp (also declared in
// Core.hpp); redeclared here so socket code need not include the heap
// headers.
const char* errnoName(int err);

// send()/sendto()/sendmsg() flags for every socket write.
#if !defined(_WIN32) && defined(MSG_NOSIGNAL)
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;
#endif

// --- fd flags ---------------------------------------------------------------

int setCloexec(int fd);       // FD_CLOEXEC
int setNonBlocking(int fd);   // O_NONBLOCK
// SO_NOSIGPIPE where it exists (macOS); a no-op returning 0 elsewhere.
int setNoSigPipe(int fd);

// socket(2) with FD_CLOEXEC (and O_NONBLOCK if asked) and SO_NOSIGPIPE.
// Returns the fd, or -1 with the errno in *err (err may be null).
int socketCloexec(int domain, int type, int protocol, bool nonBlocking, int* err);

// accept(2) with FD_CLOEXEC (and O_NONBLOCK if asked) and SO_NOSIGPIPE:
// accept4 on Linux, accept + fcntl elsewhere. EINTR is NOT retried (callers
// have their own retry policy). Returns the fd, or -1 with errno set (and the
// errno also in *err when err is non-null). `addr`/`len` may be null.
int acceptCloexec(int listenFd, bool nonBlocking, struct sockaddr* addr, socklen_t* len,
                  int* err);

// --- addresses ----------------------------------------------------------------

// A sockaddr large enough for every family (sockaddr_storage).
struct SockAddr {
#ifndef _WIN32
    struct sockaddr_storage ss;
#else
    alignas(8) unsigned char ss[128];
#endif
    socklen_t len = 0;

    SockAddr();
    struct sockaddr* get() { return reinterpret_cast<struct sockaddr*>(&ss); }
    const struct sockaddr* get() const { return reinterpret_cast<const struct sockaddr*>(&ss); }
    int family() const;   // AF_INET, AF_INET6, AF_UNIX, or AF_UNSPEC (0) when empty
};

// "a.b.c.d" or IPv6 text with an optional "%ifname" / "%index" scope, plus a
// port 0..65535 -> AF_INET / AF_INET6 sockaddr. Errors: EINVAL (bad text, a
// scope on an IPv4 address, an empty or unknown scope, a port out of range).
int inetToSockaddr(const std::string& text, int64_t port, SockAddr& out);

// AF_INET / AF_INET6 sockaddr -> (text, port). IPv6 scope ids are printed
// "%ifname", or "%<index>" when the interface has no name. False (outputs
// untouched) for other families or a short length.
bool sockaddrToInet(const struct sockaddr* sa, socklen_t len, std::string& text, int64_t& port);
inline bool sockaddrToInet(const SockAddr& sa, std::string& text, int64_t& port) {
    return sockaddrToInet(sa.get(), sa.len, text, port);
}

// The IPv6 scope text of a scope id: "lo", or "7" when unnamed. "" for 0.
std::string scopeName(uint32_t scopeId);
// "%ifname" / "%index" text (without the '%') -> scope id. False when empty,
// unknown, or out of range.
bool parseScope(const std::string& scope, uint32_t& scopeId);

// AF_UNIX sockaddr for `path` (§D.3): ENAMETOOLONG when the UTF-8 byte length
// is >= sizeof(sun_path) (108 Linux, 104 macOS), checked before anything
// else; EINVAL for an embedded NUL; ENOENT for "" (no unnamed or abstract
// addresses in v1, SD4). The length covers the path and its NUL.
int unixSockaddr(const std::string& path, SockAddr& out);
// sizeof(sockaddr_un::sun_path) on this platform (0 on Windows).
size_t unixPathMax();
// AF_UNIX sockaddr -> path ("" for unnamed and abstract addresses). False for
// other families.
bool sockaddrToUnixPath(const struct sockaddr* sa, socklen_t len, std::string& path);

// §D.4: an AF_INET sockaddr becomes the AF_INET6 ::ffff:a.b.c.d with the same
// port; any other family is left unchanged. Returns true if it converted.
bool mapIPv4ToIPv6(SockAddr& sa);

// --- name lookup --------------------------------------------------------------

// getaddrinfo error -> FErr code (§3.3.6, §D.5): EAI_NONAME / EAI_NODATA ->
// "ENOTFOUND"; EAI_AGAIN -> "EAI_AGAIN"; EAI_MEMORY -> "ENOMEM"; EAI_SYSTEM ->
// errnoName(sysErrno); anything else -> "EAI_FAIL". `sysErrno` is errno as
// captured right after getaddrinfo returned.
const char* gaiCode(int gaiErr, int sysErrno);

} // namespace Eco::System

#endif // ECO_SYSTEM_CORE_SOCKET_UTIL_HPP
