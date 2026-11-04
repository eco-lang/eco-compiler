#pragma once

#include "../IsolatedTestRunner.hpp"

// A binding body (TaskBinding.hpp) that throws: the program must end in `[eco-runtime] FATAL`.
// Each case forks the scenario from its own spawned child.
void registerTaskBindingTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
