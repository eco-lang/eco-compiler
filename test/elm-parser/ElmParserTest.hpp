#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmParserTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmParserTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-parser", "Elm Parser E2E", "elm-parser/");
}

}  // namespace ElmParserTest
