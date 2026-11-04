#pragma once

#include "../IsolatedTestRunner.hpp"

// The Regex kernel (elm-kernel-cpp/src/regex/): rooting on the error paths, exception propagation,
// interning of compiled patterns. Each case initializes its own allocator: spawned child.
void registerRegexKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
