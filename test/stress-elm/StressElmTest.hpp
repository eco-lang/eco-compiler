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
    // Some stress tests import `Eco.MVar` from the eco/kernel package;
    // plumb --local-package so those compile too. Tests that don't use
    // Eco.* ignore the flag. REPO_ROOT comes from target_compile_definitions
    // in test/CMakeLists.txt (= CMAKE_SOURCE_DIR), so this works regardless
    // of the CWD.
    std::string extraFlags =
        std::string(" --local-package eco/kernel=") + REPO_ROOT + "/eco-kernel-cpp";
    return ElmE2EBase::buildTestSuite("stress-elm", "Elm Stress E2E",
                                      "stress-elm/", extraFlags, flags);
}

}  // namespace StressElmTest
