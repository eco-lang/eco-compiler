#pragma once
#include "../ElmE2ETestBase.hpp"

// The Elm-vs-eco conformance tests (plans/char-case-mapping-elm-exact.md Step 0): stock
// elm/core programs whose CHECK lines were recorded from Elm on node
// (`run-js-e2e.js --project elm-conformance --record <Test>`), so the JS runner and this
// suite check the same expectations. Unrelated to test/conformance (Autobahn/h2spec).
namespace ElmConformanceTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildElmConformanceTestSuite() {
    return ElmE2EBase::buildTestSuite("elm-conformance", "Elm Conformance E2E", "elm-conformance/");
}

}  // namespace ElmConformanceTest
