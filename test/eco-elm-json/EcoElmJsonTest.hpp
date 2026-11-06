#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-elm-json: elm/json programs written to exercise eco runtime internals. They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoElmJsonTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoElmJsonTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-elm-json", "Eco Elm Json E2E", "eco-elm-json/");
}

}  // namespace EcoElmJsonTest
