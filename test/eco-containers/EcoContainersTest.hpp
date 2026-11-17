#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-containers: programs using the bundled eco/containers package (containers-kernel-cpp/): SeqDict,
// SeqSet and the `==` that compares SeqDicts by their entries.
namespace EcoContainersTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoContainersTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-containers", "Eco Containers E2E", "eco-containers/");
}

}  // namespace EcoContainersTest
