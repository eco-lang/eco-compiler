#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-elm-conformance: conformance programs written to exercise eco runtime internals. They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoElmConformanceTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoElmConformanceTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-elm-conformance", "Eco Elm Conformance E2E", "eco-elm-conformance/");
}

}  // namespace EcoElmConformanceTest
