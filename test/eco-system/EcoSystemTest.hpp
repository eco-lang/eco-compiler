#pragma once
#include "../ElmE2ETestBase.hpp"
#if !defined(_WIN32)
#include "../TestServerConfig.hpp"
#endif

#include <memory>
#include <string>

// REPO_ROOT (= CMAKE_SOURCE_DIR) comes from target_compile_definitions in
// test/CMakeLists.txt; see EcoKernelTest.hpp.
#ifndef REPO_ROOT
#error "REPO_ROOT not defined — add it to target_compile_definitions in test/CMakeLists.txt for this target"
#endif

namespace EcoSystemTest {

// E2E tests of the public eco/system package (plans/eco-system-library.md
// Phase 1 step 8). The tests import eco/system modules, so the compiler gets
// --local-package eco/system=<repo>/system-kernel-cpp. The suite runs in
// process-output mode: `-- CHECK:` patterns see the eco-thread output AND the
// program's raw stdout/stderr (eco/system streams write fds directly), are
// verified by the parent after the child exits, `-- EXIT: <n>` (default 0) is
// enforced, and stdin is /dev/null unless the test has `-- STDIN:` lines.
inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoSystemTestSuite() {
#if !defined(_WIN32)
    // The Http.Stream tests (Phase 8) import the generated TestServerConfig
    // (baseUrl of the shared in-process TestHttpServer, TestServerConfig.hpp).
    TestServerConfig::prepare(ElmE2EBase::findTestDir("eco-system") + "/src");
#endif
    std::string extraFlags =
        std::string(" --local-package eco/system=") + REPO_ROOT + "/system-kernel-cpp";
    return ElmE2EBase::buildTestSuite("eco-system", "Eco System E2E", "eco-system/",
                                      extraFlags, std::nullopt,
                                      /*checkProcessOutput=*/true);
}

}  // namespace EcoSystemTest
