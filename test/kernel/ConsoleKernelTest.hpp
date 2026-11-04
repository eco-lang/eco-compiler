#pragma once

#include "../IsolatedTestRunner.hpp"

// Eco.Console's log kernel (eco-kernel-cpp/src/eco-kernel/Console.cpp): a short write.
// Initializes the allocator and redirects fd 2 in a forked child: spawned child.
void registerConsoleKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
