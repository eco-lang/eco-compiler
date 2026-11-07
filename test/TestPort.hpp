// TestPort.hpp — a free TCP port per spawned E2E test child
// (plans/eco-system-library.md Phase 7 step 7.4).
//
// Test applications cannot import eco/system's unexposed modules, and the
// public API cannot ask a server which port it got, so the harness picks
// the port: before spawning a test child (JIT `test`/`stress-test` runner)
// or a test ELF (AOT runner) it picks a port and hands it to the child as
// ECO_TEST_PORT. The program reads it with `System.getEnvironmentVariables`
// (HttpServer*Test, EcoSystemHttpServer* stress programs, HarnessTestPortTest).
//
// Nothing reserves the port between the pick and the child's bind, so the
// ports come from a block below every OS's ephemeral range (Linux 32768-60999,
// macOS and Windows 49152-65535): the kernel never gives one of them to an
// outgoing connection or a bind to port 0, which is how a port picked by
// binding port 0 was once taken in that window (EADDRINUSE in CI). The picker
// walks the block from a start chosen by the process id, so two runners at
// once rarely meet, and skips a port it cannot bind (someone listens on it).
// The scripts/test-port.js picker of the JS runners uses the same block; it
// starts elsewhere because its process id differs.
#pragma once

#if !defined(_WIN32)

#include <cstdint>
#include <mutex>
#include <string>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace eco_test {

/// The block the ports come from: [kTestPortFirst, kTestPortFirst + kTestPortCount).
inline constexpr int kTestPortFirst = 20000;
inline constexpr int kTestPortCount = 10000;

/// Whether 127.0.0.1:`port` can be bound now (no SO_REUSEADDR, so a port in
/// TIME_WAIT counts as taken too).
inline bool tcpPortBindable(int port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;
    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<uint16_t>(port));
    const bool ok = ::bind(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) == 0;
    ::close(fd);
    return ok;
}

/// A TCP port on 127.0.0.1 from the test block that was free a moment ago,
/// or 0 if none could be found. Each call moves on through the block, so a
/// port comes back only after the other 9,999. Thread-safe (the AOT runner
/// spawns from several threads).
inline int pickFreeTcpPort() {
    static std::mutex m;
    static int next = -1;   // offset into the block of the next candidate
    std::lock_guard<std::mutex> lk(m);
    if (next < 0) next = static_cast<int>(::getpid() % kTestPortCount);
    for (int attempt = 0; attempt < 64; ++attempt) {
        const int port = kTestPortFirst + next;
        next = (next + 1) % kTestPortCount;
        if (tcpPortBindable(port)) return port;
    }
    return 0;
}

/// "ECO_TEST_PORT=<port>" for an environment list (AOT runner).
inline std::string testPortEnvEntry(int port) {
    return "ECO_TEST_PORT=" + std::to_string(port);
}

} // namespace eco_test

#endif // !_WIN32
