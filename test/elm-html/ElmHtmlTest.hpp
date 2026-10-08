#pragma once
#include "../ElmE2ETestBase.hpp"

namespace ElmHtmlTest {

// Native elm/html (plans/elm-html-native-kernel.md P3): every Html function
// links and runs, lazy is eager, large trees survive GC, Debug.toString on
// kernel-built values prints <internals> (D19).
inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmHtmlTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-html", "Elm Html E2E", "elm-html/");
}

}  // namespace ElmHtmlTest
