#pragma once
#include "../ElmE2ETestBase.hpp"

namespace EcoKernelTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoKernelTestSuite() {
    // These tests import `Eco.MVar` from the eco/kernel package. The
    // compiler needs --local-package so it can resolve the import to
    // the in-tree kernel package at /work/eco-kernel-cpp.
    std::string extraFlags = " --local-package eco/kernel=/work/eco-kernel-cpp";
    return ElmE2EBase::buildTestSuite("eco-kernel", "Eco Kernel E2E",
                                      "eco-kernel/", extraFlags);
}

}  // namespace EcoKernelTest
