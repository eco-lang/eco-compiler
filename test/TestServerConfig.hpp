#pragma once
//===- TestServerConfig.hpp - the HTTP test server's URLs, for E2E tests --===//
//
// The E2E suites that talk to the in-process TestHttpServer (elm-http,
// eco-kernel, eco-system; JIT runner and AOT runner) learn its ephemeral URLs
// from the ENVIRONMENT: prepare() publishes them in this process's
// environment, which every spawned test child inherits (SpawnedChildren.hpp,
// SYS_008), and each package's checked-in `TestServerConfig` module reads them
// at run time (Eco.Env.lookup / System.getEnvironmentVariables).
//
// Nothing is written into the source tree and no source is touched, so a run
// recompiles nothing because of the server, and the test binaries of
// different build trees (build/, build-validate/) can run at the same time,
// each with its own server. (It replaces a generated TestServerConfig.elm with
// the ports baked in, written into the shared test/<pkg>/src/ and followed by
// bumping every source's mtime so the harness recompiled against it.)
//
//   ECO_TEST_HTTP_URL   http://127.0.0.1:<port>
//   ECO_TEST_HTTPS_URL  https://127.0.0.1:<httpsPort>
//   CURL_CA_BUNDLE      the server's throwaway CA, so HTTPS verifies the peer
//
// POSIX only: TestHttpServer.hpp is BSD-sockets + OpenSSL (the Windows
// runners skip the E2E suites).
//===----------------------------------------------------------------------===//

#if !defined(_WIN32)

#include "TestHttpServer.hpp"

#include <cstdlib>
#include <string>

namespace TestServerConfig {

// Starts the shared server singleton (once per process) and publishes its
// URLs in the environment the test children inherit.
inline void prepare() {
    auto& server = ElmHttpTestServer::TestHttpServer::instance();
    if (!server.certPath().empty()) {
        setenv("CURL_CA_BUNDLE", server.certPath().c_str(), 1);
    }
    setenv("ECO_TEST_HTTP_URL", ("http://127.0.0.1:" + std::to_string(server.port())).c_str(), 1);
    setenv("ECO_TEST_HTTPS_URL", ("https://127.0.0.1:" + std::to_string(server.httpsPort())).c_str(), 1);
}

}  // namespace TestServerConfig

#endif  // !_WIN32
