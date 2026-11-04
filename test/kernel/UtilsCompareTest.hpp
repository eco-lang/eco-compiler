#pragma once

#include "../IsolatedTestRunner.hpp"

// Elm_Kernel_Utils_compare / cmp3 on hand-built values whose slots are boxed on one side and
// unboxed on the other. Each case initializes the allocator: spawned child.
void registerUtilsCompareTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
