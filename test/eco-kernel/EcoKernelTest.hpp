#pragma once
#include "../ElmE2ETestBase.hpp"
#include "../TestHttpServer.hpp"

#include <filesystem>
#include <fstream>
#include <string>

// REPO_ROOT (= CMAKE_SOURCE_DIR) is plumbed via target_compile_definitions
// in test/CMakeLists.txt for both `test` and `stress-test`. Fail fast at
// compile time if a consumer forgets to define it — a silent fallback would
// hide the configuration mistake until a kernel test fails to compile its
// .elm at runtime with a confusing missing-package error.
#ifndef REPO_ROOT
#error "REPO_ROOT not defined — add it to target_compile_definitions in test/CMakeLists.txt for this target"
#endif

namespace EcoKernelTest {

// Start the shared in-process server (a singleton, also used by elm-http) and
// write a generated TestServerConfig.elm carrying its base URL so the Eco.Http
// getArchive test can hit /package.zip. Mirrors ElmHttpTest::prepareServer.
inline void prepareServer() {
    int port = ElmHttpTestServer::TestHttpServer::instance().port();
    std::string testDir = ElmE2EBase::findTestDir("eco-kernel");
    std::string configPath = testDir + "/src/TestServerConfig.elm";
    std::ofstream out(configPath, std::ios::trunc);
    out << "module TestServerConfig exposing (baseUrl)\n\n\n"
        << "baseUrl : String\n"
        << "baseUrl =\n"
        << "    \"http://127.0.0.1:" << port << "\"\n";
    out.close();

    // Ephemeral port changes each run; bump test-source mtimes so the harness
    // recompiles against the current port (see ElmHttpTest::prepareServer).
    std::error_code ec;
    auto now = std::filesystem::file_time_type::clock::now();
    for (auto& e : std::filesystem::directory_iterator(testDir + "/src", ec)) {
        if (e.path().extension() == ".elm") {
            std::filesystem::last_write_time(e.path(), now, ec);
        }
    }
}

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoKernelTestSuite() {
    // These tests import `Eco.MVar` / `Eco.Http` from the eco/kernel package.
    // The compiler needs --local-package so it can resolve the import to the
    // in-tree kernel package under the repo's eco-kernel-cpp/ directory.
    // REPO_ROOT comes from target_compile_definitions in test/CMakeLists.txt
    // (= CMAKE_SOURCE_DIR), so this works regardless of the CWD.
    prepareServer();
    std::string extraFlags =
        std::string(" --local-package eco/kernel=") + REPO_ROOT + "/eco-kernel-cpp";
    return ElmE2EBase::buildTestSuite("eco-kernel", "Eco Kernel E2E",
                                      "eco-kernel/", extraFlags);
}

}  // namespace EcoKernelTest
