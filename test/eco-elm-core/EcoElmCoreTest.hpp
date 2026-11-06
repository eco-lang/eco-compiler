#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-elm-core: elm/core programs written to exercise eco runtime internals. They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoElmCoreTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoElmCoreTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-elm-core", "Eco Elm Core E2E", "eco-elm-core/");
}

}  // namespace EcoElmCoreTest
