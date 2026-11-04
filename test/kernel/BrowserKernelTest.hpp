#pragma once

#include "../IsolatedTestRunner.hpp"

// The native elm/browser and elm/file kernel stubs: a clear exit 1, or a Task failing with NotFound.
// The stubs that exit run in a forked child of a spawned child.
void registerBrowserKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
