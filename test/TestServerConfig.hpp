#pragma once
//===- TestServerConfig.hpp - TestServerConfig.elm for HTTP E2E suites ----===//
//
// The E2E suites that talk to the in-process TestHttpServer (elm-http,
// eco-kernel, eco-system; JIT runner and AOT runner) import a generated
// `TestServerConfig` module carrying the server's ephemeral URLs. This is the
// one generator they all call (plans/eco-system-library.md Phase 8 step 8.3,
// review finding R3.20).
//
// The generated file has no `main`, so test discovery skips it while it stays
// importable; it is git-ignored in every package that uses it.
//
// POSIX only: TestHttpServer.hpp is BSD-sockets + OpenSSL (the Windows
// runners skip the E2E suites).
//===----------------------------------------------------------------------===//

#if !defined(_WIN32)

#include "TestHttpServer.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

namespace TestServerConfig {

// Writes `<srcDir>/TestServerConfig.elm` exposing `baseUrl` and
// `httpsBaseUrl` for the given ports.
inline void writeElmModule(const std::string& srcDir, int port, int httpsPort) {
    std::ofstream out(srcDir + "/TestServerConfig.elm", std::ios::trunc);
    out << "module TestServerConfig exposing (baseUrl, httpsBaseUrl)\n\n\n"
        << "baseUrl : String\n"
        << "baseUrl =\n"
        << "    \"http://127.0.0.1:" << port << "\"\n\n\n"
        << "httpsBaseUrl : String\n"
        << "httpsBaseUrl =\n"
        << "    \"https://127.0.0.1:" << httpsPort << "\"\n";
}

// The server binds an ephemeral port each run, so baseUrl changes — but the
// harness caches each test's .mlir by that test's own mtime and would not
// notice the (unchanged-mtime) dependency change. Bump the mtime of every
// test source so needsRecompile fires and each test recompiles against the
// current port. (Touching sources uses the compiler's normal incremental
// path — unlike deleting the .mlir cache, which corrupts eco-stuff/.)
inline void touchElmSources(const std::string& srcDir) {
    std::error_code ec;
    auto now = std::filesystem::file_time_type::clock::now();
    for (auto& e : std::filesystem::directory_iterator(srcDir, ec)) {
        if (e.path().extension() == ".elm") {
            std::filesystem::last_write_time(e.path(), now, ec);
        }
    }
}

// Starts the shared server singleton (in the PARENT test process, before any
// test forks), points libcurl in the forked children at its throwaway CA so
// HTTPS requests verify the peer, writes `<srcDir>/TestServerConfig.elm` and
// bumps the sources' mtimes.
inline void prepare(const std::string& srcDir) {
    auto& server = ElmHttpTestServer::TestHttpServer::instance();
    if (!server.certPath().empty()) {
        setenv("CURL_CA_BUNDLE", server.certPath().c_str(), 1);
    }
    writeElmModule(srcDir, server.port(), server.httpsPort());
    touchElmSources(srcDir);
}

}  // namespace TestServerConfig

#endif  // !_WIN32
