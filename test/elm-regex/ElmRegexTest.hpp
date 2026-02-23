#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmRegexTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmRegexTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-regex", "Elm Regex E2E", "elm-regex/");
}

}  // namespace ElmRegexTest
