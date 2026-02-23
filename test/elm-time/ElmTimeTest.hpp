#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmTimeTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmTimeTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-time", "Elm Time E2E", "elm-time/");
}

}  // namespace ElmTimeTest
