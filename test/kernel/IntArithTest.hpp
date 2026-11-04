#pragma once

#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"

// The Int arithmetic kernel exports (Elm_Kernel_Basics_*_Int, modBy) and the runtime's eco_int_pow.
// In-process cases.
void registerIntArithTests(Testing::TestSuite& suite);
// Cases that fork a child (kernel modBy 0): each in a spawned child.
void registerIntArithIsolatedTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
