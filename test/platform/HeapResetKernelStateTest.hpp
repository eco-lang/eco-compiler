#pragma once

#include "../IsolatedTestRunner.hpp"

// Kernel state that lives outside the heap, across a heap reset: Eco.Kernel.Runtime's saved state,
// the Time and Http kernels' root scanners, MVars. Each case resets the heap: spawned child.
void registerHeapResetKernelStateTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
