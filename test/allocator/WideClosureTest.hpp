#pragma once

namespace Testing {
class TestSuite;
}

// Register the closure layout v2 tests (plans/wide-object-tail-kind-words-phase-2.md 2.6.7).
void registerWideClosureTests(Testing::TestSuite& suite);
