#pragma once

#include "../IsolatedTestRunner.hpp"

// The JsArray kernel entry points (elm-kernel-cpp/src/core/JsArrayExports.cpp): index range and
// element kinds. Each case initializes the allocator: spawned child.
void registerJsArrayKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
