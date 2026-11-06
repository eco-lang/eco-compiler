#pragma once
#include "../ElmE2ETestBase.hpp"

// test/eco-mlir: IR assertions: programs whose CHECK-MLIR / TEXT-MLIR lines check the MLIR eco generates. They are eco's own tests and are not part of elm-test-suite (see
// local-dev/sync.json, "notSynced").
namespace EcoMlirTest {

inline std::unique_ptr<ElmE2EBase::ElmE2EParallelTestSuite> buildEcoMlirTestSuite() {
    return ElmE2EBase::buildTestSuite("eco-mlir", "Eco MLIR E2E", "eco-mlir/");
}

}  // namespace EcoMlirTest
