#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-elm-regex: elm/regex programs written to exercise eco runtime internals. They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoElmRegexTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoElmRegexTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-elm-regex", "Eco Elm Regex E2E", "eco-elm-regex/");
}

}  // namespace EcoElmRegexTest
