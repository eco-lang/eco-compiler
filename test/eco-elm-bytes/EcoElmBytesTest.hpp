#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-elm-bytes: elm/bytes programs written to exercise eco internals (fusion, specialisation, GC). They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoElmBytesTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoElmBytesTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-elm-bytes", "Eco Elm Bytes E2E", "eco-elm-bytes/");
}

}  // namespace EcoElmBytesTest
