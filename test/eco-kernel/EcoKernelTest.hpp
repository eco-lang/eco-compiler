#pragma once
#include "../ElmE2ETestBase.hpp"
#if !defined(_WIN32)
#include "../TestServerConfig.hpp"
#endif

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

#if defined(_WIN32)
// Windows v1: skip — depends on TestHttpServer (POSIX sockets + OpenSSL).
inline void prepareServer() {}
inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoKernelTestSuite() {
    // Empty suite (see ElmHttpTest.hpp for the rationale). Builder type
    // matches the POSIX path so test/main.cpp's suite.add() resolves.
    return ElmE2EBase::buildTestSuite("eco-kernel", "Eco Kernel E2E (skipped on Windows)",
                                       "win-skipped-eco-kernel/");
}
}  // namespace EcoKernelTest
#else

// Start the shared in-process server (a singleton, also used by elm-http and
// eco-system) and write the generated TestServerConfig.elm carrying its base
// URL, so the Eco.Http getArchive test can hit /package.zip
// (TestServerConfig.hpp).
inline void prepareServer() {
    TestServerConfig::prepare(ElmE2EBase::findTestDir("eco-kernel") + "/src");
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
#endif  // !_WIN32
