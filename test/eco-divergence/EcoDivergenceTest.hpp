#pragma once
#include "../ElmE2ETestBase.hpp"

// Programs whose behaviour under eco deliberately or knowingly differs from Elm 0.19.1's: 64-bit
// Int, IEEE Float semantics, Unicode simple case mapping, strict UTF-8, Elm bugs eco fixes,
// features eco rejects, and programs past node's stack limits. Each carries a
// `-- DIVERGENCE: <how Elm behaves instead>` line, and its CHECK lines are eco's behaviour. Only
// the native harnesses run them; the stock-Elm and JS runners do not.
namespace EcoDivergenceTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoDivergenceTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-divergence", "Eco Divergence E2E", "eco-divergence/");
}

}  // namespace EcoDivergenceTest
