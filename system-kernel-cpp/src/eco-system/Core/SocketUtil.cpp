//===- SocketUtil.cpp - Small POSIX socket helpers shared by eco/system ---===//
//
// See SocketUtil.hpp. Pure functions; safe on any thread.
//
// Templates used: none (POD only, G1).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/SocketUtil.hpp"

#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdlib>
#include <cstring>

#ifndef _WIN32
#include <arpa/inet.h>
#include <fcntl.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace Eco::System {

SockAddr::SockAddr() { std::memset(&ss, 0, sizeof(ss)); }

#ifdef _WIN32

// ---------------------------------------------------------------------------
// Windows stubs (§1): nothing reaches these on Windows (the kernels fail
// ENOTSUP first); they exist so EcoSystem_Core links.
// ---------------------------------------------------------------------------

int SockAddr::family() const { return 0; }
int setCloexec(int) { return ENOTSUP; }
int setNonBlocking(int) { return ENOTSUP; }
int setNoSigPipe(int) { return 0; }
int socketCloexec(int, int, int, bool, int* err) {
    if (err) *err = ENOTSUP;
    errno = ENOTSUP;
    return -1;
}
int acceptCloexec(int, bool, struct sockaddr*, socklen_t*, int* err) {
    if (err) *err = ENOTSUP;
    errno = ENOTSUP;
    return -1;
}
int inetToSockaddr(const std::string&, int64_t, SockAddr&) { return ENOTSUP; }
bool sockaddrToInet(const struct sockaddr*, socklen_t, std::string&, int64_t&) { return false; }
std::string scopeName(uint32_t scopeId) { return scopeId == 0 ? std::string() : std::to_string(scopeId); }
bool parseScope(const std::string&, uint32_t&) { return false; }
int unixSockaddr(const std::string&, SockAddr&) { return ENOTSUP; }
size_t unixPathMax() { return 0; }
bool sockaddrToUnixPath(const struct sockaddr*, socklen_t, std::string&) { return false; }
bool mapIPv4ToIPv6(SockAddr&) { return false; }
const char* gaiCode(int, int) { return "EAI_FAIL"; }

#else // POSIX

int SockAddr::family() const { return len == 0 ? AF_UNSPEC : ss.ss_family; }

// ---------------------------------------------------------------------------
// fd flags
// ---------------------------------------------------------------------------

int setCloexec(int fd) {
    int fl = ::fcntl(fd, F_GETFD);
    if (fl < 0) return errno;
    if (fl & FD_CLOEXEC) return 0;
    if (::fcntl(fd, F_SETFD, fl | FD_CLOEXEC) < 0) return errno;
    return 0;
}

int setNonBlocking(int fd) {
    int fl = ::fcntl(fd, F_GETFL);
    if (fl < 0) return errno;
    if (fl & O_NONBLOCK) return 0;
    if (::fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return errno;
    return 0;
}

int setNoSigPipe(int fd) {
#if defined(SO_NOSIGPIPE)
    int one = 1;
    if (::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) return errno;
#else
    (void)fd;   // MSG_NOSIGNAL (kSendFlags) on every send instead
#endif
    return 0;
}

namespace {

[[maybe_unused]] void closeQuietly(int fd) {   // unused where SOCK_CLOEXEC exists
    int saved = errno;
    while (::close(fd) < 0 && errno == EINTR) {
    }
    errno = saved;
}

} // namespace

int socketCloexec(int domain, int type, int protocol, bool nonBlocking, int* err) {
#if defined(SOCK_CLOEXEC) && defined(SOCK_NONBLOCK)
    int fd = ::socket(domain, type | SOCK_CLOEXEC | (nonBlocking ? SOCK_NONBLOCK : 0), protocol);
    if (fd < 0) {
        if (err) *err = errno;
        return -1;
    }
#else
    int fd = ::socket(domain, type, protocol);
    if (fd < 0) {
        if (err) *err = errno;
        return -1;
    }
    int e = setCloexec(fd);
    if (e == 0 && nonBlocking) e = setNonBlocking(fd);
    if (e != 0) {
        closeQuietly(fd);
        if (err) *err = e;
        errno = e;
        return -1;
    }
#endif
    (void)setNoSigPipe(fd);
    return fd;
}

int acceptCloexec(int listenFd, bool nonBlocking, struct sockaddr* addr, socklen_t* len, int* err) {
#if defined(__linux__)
    int fd = ::accept4(listenFd, addr, len, SOCK_CLOEXEC | (nonBlocking ? SOCK_NONBLOCK : 0));
    if (fd < 0) {
        if (err) *err = errno;
        return -1;
    }
#else
    int fd = ::accept(listenFd, addr, len);
    if (fd < 0) {
        if (err) *err = errno;
        return -1;
    }
    // A failure here leaves the fd usable (the window is closed by
    // POSIX_SPAWN_CLOEXEC_DEFAULT on macOS, SF9); only O_NONBLOCK matters.
    (void)setCloexec(fd);
    if (nonBlocking) {
        int e = setNonBlocking(fd);
        if (e != 0) {
            closeQuietly(fd);
            if (err) *err = e;
            errno = e;
            return -1;
        }
    }
#endif
    (void)setNoSigPipe(fd);
    return fd;
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

std::string scopeName(uint32_t scopeId) {
    if (scopeId == 0) return std::string();
    char buf[IF_NAMESIZE + 1];
    std::memset(buf, 0, sizeof(buf));
    if (::if_indextoname(scopeId, buf) != nullptr && buf[0] != '\0') return std::string(buf);
    return std::to_string(scopeId);
}

bool parseScope(const std::string& scope, uint32_t& scopeId) {
    if (scope.empty() || scope.size() > 15) return false;   // §D.1: 1-15 characters
    bool digits = true;
    for (char c : scope) {
        if (c < '0' || c > '9') { digits = false; break; }
    }
    if (digits) {
        if (scope.size() > 10) return false;
        unsigned long long v = std::strtoull(scope.c_str(), nullptr, 10);
        if (v > 0xFFFFFFFFull) return false;
        scopeId = static_cast<uint32_t>(v);
        return true;
    }
    unsigned idx = ::if_nametoindex(scope.c_str());
    if (idx == 0) return false;
    scopeId = idx;
    return true;
}

int inetToSockaddr(const std::string& text, int64_t port, SockAddr& out) {
    if (port < 0 || port > 65535) return EINVAL;
    if (text.find('\0') != std::string::npos) return EINVAL;
    std::string addr = text;
    std::string scope;
    bool hasScope = false;
    size_t pct = text.find('%');
    if (pct != std::string::npos) {
        addr = text.substr(0, pct);
        scope = text.substr(pct + 1);
        hasScope = true;
    }
    SockAddr r;
    struct in_addr a4;
    if (!hasScope && ::inet_pton(AF_INET, addr.c_str(), &a4) == 1) {
        auto* s = reinterpret_cast<struct sockaddr_in*>(&r.ss);
        s->sin_family = AF_INET;
        s->sin_port = htons(static_cast<uint16_t>(port));
        s->sin_addr = a4;
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
        s->sin_len = sizeof(struct sockaddr_in);
#endif
        r.len = sizeof(struct sockaddr_in);
        out = r;
        return 0;
    }
    struct in6_addr a6;
    if (::inet_pton(AF_INET6, addr.c_str(), &a6) == 1) {
        uint32_t scopeId = 0;
        if (hasScope && !parseScope(scope, scopeId)) return EINVAL;
        auto* s = reinterpret_cast<struct sockaddr_in6*>(&r.ss);
        s->sin6_family = AF_INET6;
        s->sin6_port = htons(static_cast<uint16_t>(port));
        s->sin6_addr = a6;
        s->sin6_scope_id = scopeId;
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
        s->sin6_len = sizeof(struct sockaddr_in6);
#endif
        r.len = sizeof(struct sockaddr_in6);
        out = r;
        return 0;
    }
    return EINVAL;
}

bool sockaddrToInet(const struct sockaddr* sa, socklen_t len, std::string& text, int64_t& port) {
    if (sa == nullptr) return false;
    char buf[INET6_ADDRSTRLEN + 1];
    if (sa->sa_family == AF_INET && len >= static_cast<socklen_t>(sizeof(struct sockaddr_in))) {
        const auto* s = reinterpret_cast<const struct sockaddr_in*>(sa);
        if (::inet_ntop(AF_INET, &s->sin_addr, buf, sizeof(buf)) == nullptr) return false;
        text = buf;
        port = ntohs(s->sin_port);
        return true;
    }
    if (sa->sa_family == AF_INET6 && len >= static_cast<socklen_t>(sizeof(struct sockaddr_in6))) {
        const auto* s = reinterpret_cast<const struct sockaddr_in6*>(sa);
        if (::inet_ntop(AF_INET6, &s->sin6_addr, buf, sizeof(buf)) == nullptr) return false;
        std::string t = buf;
        if (s->sin6_scope_id != 0) {
            t += '%';
            t += scopeName(s->sin6_scope_id);
        }
        text = std::move(t);
        port = ntohs(s->sin6_port);
        return true;
    }
    return false;
}

size_t unixPathMax() { return sizeof(sockaddr_un::sun_path); }

int unixSockaddr(const std::string& path, SockAddr& out) {
    // §D.3: the length check comes first (both backends report ENAMETOOLONG
    // before any syscall), then the v1 restrictions.
    if (path.size() >= unixPathMax()) return ENAMETOOLONG;
    if (path.empty()) return ENOENT;
    if (path.find('\0') != std::string::npos) return EINVAL;
    SockAddr r;
    auto* u = reinterpret_cast<struct sockaddr_un*>(&r.ss);
    u->sun_family = AF_UNIX;
    std::memcpy(u->sun_path, path.data(), path.size());
    u->sun_path[path.size()] = '\0';
    r.len = static_cast<socklen_t>(offsetof(struct sockaddr_un, sun_path) + path.size() + 1);
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    u->sun_len = static_cast<unsigned char>(r.len);
#endif
    out = r;
    return 0;
}

bool sockaddrToUnixPath(const struct sockaddr* sa, socklen_t len, std::string& path) {
    if (sa == nullptr || sa->sa_family != AF_UNIX) return false;
    const size_t off = offsetof(struct sockaddr_un, sun_path);
    if (len <= static_cast<socklen_t>(off)) {   // unnamed
        path.clear();
        return true;
    }
    const auto* u = reinterpret_cast<const struct sockaddr_un*>(sa);
    size_t max = static_cast<size_t>(len) - off;
    if (max > unixPathMax()) max = unixPathMax();
    if (u->sun_path[0] == '\0') {   // abstract (Linux): not supported in v1 (SD4)
        path.clear();
        return true;
    }
    path.assign(u->sun_path, ::strnlen(u->sun_path, max));
    return true;
}

bool mapIPv4ToIPv6(SockAddr& sa) {
    if (sa.family() != AF_INET) return false;
    struct sockaddr_in v4;
    std::memcpy(&v4, &sa.ss, sizeof(v4));
    SockAddr r;
    auto* s = reinterpret_cast<struct sockaddr_in6*>(&r.ss);
    s->sin6_family = AF_INET6;
    s->sin6_port = v4.sin_port;
    unsigned char* b = reinterpret_cast<unsigned char*>(&s->sin6_addr);
    std::memset(b, 0, 10);
    b[10] = 0xff;
    b[11] = 0xff;
    std::memcpy(b + 12, &v4.sin_addr, 4);
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    s->sin6_len = sizeof(struct sockaddr_in6);
#endif
    r.len = sizeof(struct sockaddr_in6);
    sa = r;
    return true;
}

// ---------------------------------------------------------------------------
// Name lookup
// ---------------------------------------------------------------------------

const char* gaiCode(int gaiErr, int sysErrno) {
    (void)sysErrno;
    switch (gaiErr) {
        case EAI_NONAME: return "ENOTFOUND";
#if defined(EAI_NODATA) && (EAI_NODATA != EAI_NONAME)
        case EAI_NODATA: return "ENOTFOUND";
#endif
        case EAI_AGAIN: return "EAI_AGAIN";
        case EAI_MEMORY: return "ENOMEM";
#if defined(EAI_SYSTEM)
        case EAI_SYSTEM: return errnoName(sysErrno);
#endif
        default: return "EAI_FAIL";
    }
}

#endif // POSIX

} // namespace Eco::System
