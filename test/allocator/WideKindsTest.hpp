#pragma once

namespace Testing {
class TestSuite;
}

// Register the wide-object slot-kind tests (plans/wide-object-tail-kind-words-phase-1.md,
// steps 1c.1-1c.5) with the given suite.
void registerWideKindsTests(Testing::TestSuite& suite);
