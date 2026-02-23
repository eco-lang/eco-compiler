#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmUrlTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmUrlTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-url", "Elm Url E2E", "elm-url/");
}

}  // namespace ElmUrlTest
