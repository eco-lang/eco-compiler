#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmCoreTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmCoreTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-core", "Elm Core E2E", "elm-core/");
}

}  // namespace ElmCoreTest
