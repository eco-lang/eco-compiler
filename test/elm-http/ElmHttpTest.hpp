#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmHttpTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmHttpTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-http", "Elm Http E2E", "elm-http/");
}

}  // namespace ElmHttpTest
