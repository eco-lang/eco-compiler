#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmJsonTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmJsonTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-json", "Elm Json E2E", "elm-json/");
}

}  // namespace ElmJsonTest
