// TestPort.hpp — a free TCP port per forked E2E test child
// (plans/eco-system-library.md Phase 7 step 7.4).
//
// Test applications cannot import eco/system's unexposed modules, and the
// public API cannot ask a server which port it got, so the harness picks
// the port: before forking a test child (JIT `test`/`stress-test` runner)
// or spawning a test ELF (AOT runner) it binds 127.0.0.1:0, reads the port
// back, closes the socket, and hands it to the child as ECO_TEST_PORT. The
// program reads it with `System.getEnvironmentVariables` (HttpServer*Test,
// EcoSystemHttpServer* stress programs, HarnessTestPortTest).
//
// Ports handed out recently are remembered and not handed out again, so two
// concurrently running children never get the same port from this process.
// Nothing reserves the port between the close and the child's bind; another
// process may take it in that window (unlikely: the kernel picks ephemeral
// ports at random).
#pragma once

#if !defined(_WIN32)

#include <deque>
#include <mutex>
#include <string>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace eco_test {

/// A TCP port on 127.0.0.1 that was free a moment ago, or 0 if none could be
/// found. Thread-safe (the AOT runner spawns from several threads).
inline int pickFreeTcpPort() {
    static std::mutex m;
    static std::deque<int> recent;   // the last 256 ports handed out
    std::lock_guard<std::mutex> lk(m);
    for (int attempt = 0; attempt < 16; ++attempt) {
        int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return 0;
        struct sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        int port = 0;
        if (::bind(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) == 0) {
            socklen_t len = sizeof(addr);
            if (::getsockname(fd, reinterpret_cast<struct sockaddr*>(&addr), &len) == 0)
                port = ntohs(addr.sin_port);
        }
        ::close(fd);
        if (port == 0) return 0;
        bool reused = false;
        for (int p : recent) {
            if (p == port) { reused = true; break; }
        }
        if (reused) continue;
        recent.push_back(port);
        if (recent.size() > 256) recent.pop_front();
        return port;
    }
    return 0;
}

/// "ECO_TEST_PORT=<port>" for an environment list (AOT runner).
inline std::string testPortEnvEntry(int port) {
    return "ECO_TEST_PORT=" + std::to_string(port);
}

} // namespace eco_test

#endif // !_WIN32
