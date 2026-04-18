#pragma once
#include "../ElmE2ETestBase.hpp"

namespace StressElmTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildStressElmTestSuite() {
    return ElmE2EBase::buildTestSuite("stress-elm", "Elm Stress E2E", "stress-elm/");
}

}  // namespace StressElmTest
