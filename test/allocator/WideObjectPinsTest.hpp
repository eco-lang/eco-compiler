#pragma once

namespace Testing {
class TestSuite;
}

// Register the wide-object pin tests (plans/wide-object-tail-kind-words-phase-0.md,
// step 0.6d) with the given suite.
void registerWideObjectPinsTests(Testing::TestSuite& suite);
