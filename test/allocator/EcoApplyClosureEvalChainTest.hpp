#pragma once

namespace Testing {
class TestSuite;
}

// Register over-saturated eco_apply_closure_eval chaining tests
// (RUNTIME_CLOSURE_004) with the given suite.
void registerEcoApplyClosureEvalChainTests(Testing::TestSuite& suite);
