#pragma once
#include "../ElmE2ETestBase.hpp"
#if !defined(_WIN32)
#include "../TestHttpServer.hpp"
#endif

#include <cstdlib>
#include <filesystem>
#include <fstream>
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

// Start the in-process reflector server (parent process) and write a generated
// TestServerConfig.elm carrying its base URL, so the .elm request tests can
// import `TestServerConfig.baseUrl`. Done before the suite forks per-test
// children. TestServerConfig.elm has no `main`, so discoverTests skips it as a
// runnable test while leaving it importable.
inline void prepareServer() {
    auto& server = ElmHttpTestServer::TestHttpServer::instance();
    int port = server.port();
    int httpsPort = server.httpsPort();

    // Point libcurl (in the forked test children) at the server's throwaway CA
    // so HTTPS requests verify the peer. Set before any test forks.
    if (!server.certPath().empty()) {
        setenv("CURL_CA_BUNDLE", server.certPath().c_str(), 1);
    }

    std::string testDir = ElmE2EBase::findTestDir("elm-http");
    std::string configPath = testDir + "/src/TestServerConfig.elm";
    std::ofstream out(configPath, std::ios::trunc);
    out << "module TestServerConfig exposing (baseUrl, httpsBaseUrl)\n\n\n"
        << "baseUrl : String\n"
        << "baseUrl =\n"
        << "    \"http://127.0.0.1:" << port << "\"\n\n\n"
        << "httpsBaseUrl : String\n"
        << "httpsBaseUrl =\n"
        << "    \"https://127.0.0.1:" << httpsPort << "\"\n";
    out.close();

    // The server binds an ephemeral port each run, so baseUrl in
    // TestServerConfig.elm changes — but the harness caches each test's .mlir
    // by that test's own mtime and would not notice the (unchanged-mtime)
    // dependency change. Bump the mtime of every test source so needsRecompile
    // fires and each test recompiles against the current port. (Touching source
    // uses the compiler's normal incremental path — unlike deleting the .mlir
    // cache, which corrupts eco-stuff/ artifacts.)
    std::error_code ec;
    auto now = std::filesystem::file_time_type::clock::now();
    for (auto& e : std::filesystem::directory_iterator(testDir + "/src", ec)) {
        if (e.path().extension() == ".elm") {
            std::filesystem::last_write_time(e.path(), now, ec);
        }
    }
}

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmHttpTestSuite() {
    prepareServer();
    return ElmE2EBase::buildTestSuite("elm-http", "Elm Http E2E", "elm-http/");
}

}  // namespace ElmHttpTest
#endif  // !_WIN32
