#pragma once
#include "../ElmE2ETestBase.hpp"
#if !defined(_WIN32)
#include "../TestServerConfig.hpp"
#endif

#include <string>

namespace ElmHttpTest {

#if defined(_WIN32)
// Windows v1: the elm-http E2E suite needs a TLS-capable in-process HTTP
// reflector server (TestHttpServer.hpp), which is BSD-sockets +
// OpenSSL-based. Both are POSIX-only paths; porting them to schannel +
// winsock is W5 follow-up. Return an empty suite so the test binary still
// links and the rest of the suite runs.
inline void prepareServer() {}
inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmHttpTestSuite() {
    // Empty suite: the type matches the POSIX builder so the suite.add()
    // call sites in test/main.cpp resolve. The Windows runner threads no
    // tests through; the rest of the binary keeps building.
    return ElmE2EBase::buildTestSuite("elm-http", "Elm Http E2E (skipped on Windows)",
                                       "win-skipped-elm-http/");
}
}  // namespace ElmHttpTest
#else

// Start the in-process reflector server (parent process) and write the
// generated TestServerConfig.elm (baseUrl, httpsBaseUrl) the .elm request
// tests import, before the suite forks per-test children (TestServerConfig.hpp).
inline void prepareServer() {
    TestServerConfig::prepare(ElmE2EBase::findTestDir("elm-http") + "/src");
}

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmHttpTestSuite() {
    prepareServer();
    return ElmE2EBase::buildTestSuite("elm-http", "Elm Http E2E", "elm-http/");
}

}  // namespace ElmHttpTest
#endif  // !_WIN32
