#pragma once

#include "../IsolatedTestRunner.hpp"

// The Debug kernel (Elm_Kernel_Debug_todo) under output capture. Forks from a spawned child.
void registerDebugKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
