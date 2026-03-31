#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmTest {

using ElmE2EBase::getAccumulatedStats;

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmTestSuite() {
    return ElmE2EBase::buildTestSuite("elm", "Elm E2E", "elm/");
}

}  // namespace ElmTest
