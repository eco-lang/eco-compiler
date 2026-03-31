#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmBytesTest {

using ElmE2EBase::getAccumulatedStats;

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmBytesTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-bytes", "Elm Bytes E2E", "elm-bytes/");
}

}  // namespace ElmBytesTest
