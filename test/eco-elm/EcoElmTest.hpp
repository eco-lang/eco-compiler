#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-elm: Elm programs written to exercise eco compiler and runtime internals. They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoElmTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoElmTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-elm", "Eco Elm E2E", "eco-elm/");
}

}  // namespace EcoElmTest
