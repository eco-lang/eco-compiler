#pragma once
#include "../ElmE2ETestBase.hpp"

namespace StressElmTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildStressElmTestSuite() {
    // Some stress tests import `Eco.MVar` from the eco/kernel package;
    // plumb --local-package so those compile too. Tests that don't use
    // Eco.* ignore the flag.
    std::string extraFlags = " --local-package eco/kernel=/work/eco-kernel-cpp";
    return ElmE2EBase::buildTestSuite("stress-elm", "Elm Stress E2E",
                                      "stress-elm/", extraFlags);
}

}  // namespace StressElmTest
