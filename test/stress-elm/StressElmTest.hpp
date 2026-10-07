#pragma once
#include "../ElmE2ETestBase.hpp"

// REPO_ROOT (= CMAKE_SOURCE_DIR) is plumbed via target_compile_definitions
// in test/CMakeLists.txt for both `test` and `stress-test`. Fail fast at
// compile time if a consumer forgets to define it — a silent fallback would
// hide the configuration mistake until a kernel test fails to compile its
// .elm at runtime with a confusing missing-package error.
#ifndef REPO_ROOT
#error "REPO_ROOT not defined — add it to target_compile_definitions in test/CMakeLists.txt for this target"
#endif

namespace StressElmTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildStressElmTestSuite(
    std::optional<ElmE2EBase::StressFlags> flags = std::nullopt) {
    // Some stress tests import `Eco.MVar` from the eco/kernel package, and
    // EcoSystem*.elm programs import the eco/system package
    // (plans/eco-system-library.md Phase 1 step 8h); plumb both
    // --local-package mappings so those compile. Tests that use neither
    // ignore the flags. Repeating --local-package needs the compiler change
    // of Phase 1 step 4. REPO_ROOT comes from target_compile_definitions in
    // test/CMakeLists.txt (= CMAKE_SOURCE_DIR), so this works regardless of
    // the CWD.
    std::string extraFlags =
        std::string(" --local-package eco/kernel=") + REPO_ROOT + "/eco-kernel-cpp" +
        " --local-package eco/system=" + REPO_ROOT + "/system-kernel-cpp";
    return ElmE2EBase::buildTestSuite("stress-elm", "Elm Stress E2E",
                                      "stress-elm/", extraFlags, flags);
}

}  // namespace StressElmTest
