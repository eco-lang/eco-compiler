#pragma once

namespace Testing {
class TestSuite;
}

// Register the wide Custom/Record layout-C tests (plans/wide-object-tail-kind-words-phase-3.md,
// step 3A.9, T1-T14) with the given suite. Every test name starts with "wide:".
void registerWideObjectTests(Testing::TestSuite& suite);
