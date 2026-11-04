// HTTP server unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/HttpServer/), next to
// the wire-format and protocol tests in EcoSystemCoreTest.cpp.
//
// HTTPSRV-06: `HttpSrv::listenOn` mapped every getaddrinfo failure to "ENOTFOUND" (HttpServerService.cpp,
// `if (gai != 0)`), so a transient resolver outage (EAI_AGAIN), an out-of-memory (EAI_MEMORY) and a system error
// (EAI_SYSTEM + errno) all looked like "no such host"; it now uses `gaiCode`. Expected, as node formats it and as
// Socket.cpp does:
// code "EAI_AGAIN" with message "getaddrinfo EAI_AGAIN some.host", "ENOMEM", the errno name for EAI_SYSTEM, and
// EAI_NONAME stays "ENOTFOUND". The guard injects stub resolvers through setListenResolverForTest (test hook).
//
// The related HTTP server bugs have E2E tests (test/eco-system/src/HttpServerHostStrictTest.elm,
// HttpServerExpectHttp10Test.elm, LiveHttpUpgradeLateTest.elm), static checks (since retired, see
// plans/kernel-lib-bug-fixes.md) or have no test.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/HttpServer/HttpServerService.hpp"

#include <cerrno>
#include <cstdio>
#include <string>

#if !defined(_WIN32)
#include <netdb.h>
#endif

namespace {

#if ECO_TEST_HOOKS && !defined(_WIN32)

namespace HS = Eco::System::HttpSrv;

int gStubCalls = 0;

int stubAgain(const char*, const char*, const addrinfo*, addrinfo**) { ++gStubCalls; return EAI_AGAIN; }
int stubMemory(const char*, const char*, const addrinfo*, addrinfo**) { ++gStubCalls; return EAI_MEMORY; }
int stubSystem(const char*, const char*, const addrinfo*, addrinfo**) {
    ++gStubCalls;
    errno = ECONNREFUSED;
    return EAI_SYSTEM;
}
int stubNoName(const char*, const char*, const addrinfo*, addrinfo**) { ++gStubCalls; return EAI_NONAME; }

struct Seen {
    bool called;
    std::string code;
    std::string message;
};

Seen listenWith(HS::GetaddrinfoFn fn) {
    gStubCalls = 0;
    HS::GetaddrinfoFn prev = HS::setListenResolverForTest(fn);
    HS::ListenResult r = HS::listenOn("some.host", 0);
    HS::setListenResolverForTest(prev);
    return Seen{gStubCalls == 1, r.code, r.message};
}

void testListenGaiCodes() {
    std::printf("http-server/listen-on-getaddrinfo-error-codes\n");
    Seen again = listenWith(stubAgain);
    Seen memory = listenWith(stubMemory);
    Seen system = listenWith(stubSystem);
    Seen noName = listenWith(stubNoName);
    // Preconditions: each stub was the resolver listenOn used, and EAI_NONAME keeps its documented code.
    CHECK_MSG(again.called && memory.called && system.called && noName.called, "a stub resolver was not called");
    CHECK_MSG(noName.code == "ENOTFOUND", "EAI_NONAME gave " + noName.code);
    CHECK_MSG(noName.message == "getaddrinfo ENOTFOUND some.host", "EAI_NONAME message: " + noName.message);

    CHECK_MSG(again.code == "EAI_AGAIN" && again.message == "getaddrinfo EAI_AGAIN some.host",
              "EAI_AGAIN -> " + again.code + " (" + again.message + ")");
    CHECK_MSG(memory.code == "ENOMEM" && memory.message == "getaddrinfo ENOMEM some.host",
              "EAI_MEMORY -> " + memory.code + " (" + memory.message + ")");
    CHECK_MSG(system.code == "ECONNREFUSED", "EAI_SYSTEM/ECONNREFUSED -> " + system.code);
}

#else

void testListenGaiCodes() {
    std::printf("http-server/listen-on-getaddrinfo-error-codes skipped: no test hooks in this build\n");
}

#endif

}  // namespace

void runHttpServerTests() {
    testListenGaiCodes();
}

void registerHttpServerScenarios() {}
