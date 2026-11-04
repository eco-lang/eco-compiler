#pragma once

// elm-kernel-time-test: unit tests of elm-kernel-cpp's time code (src/time/), which the `test`
// binary does not link. CHECK: test/eco-system-core/CoreCheck.hpp. Child scenarios:
// test/ChildScenario.hpp.

#include "../ChildScenario.hpp"
#include "../eco-system-core/CoreCheck.hpp"

// Initializes the allocator on this thread and the Scheduler singleton. The parent process has
// called it before runTimeKernelTests; a child scenario calls it itself. Call it once per process
// (the heap must not be reset, RESET-02).
void initTimeRuntime();

// The in-process checks (TimeKernelTest.cpp).
void runTimeKernelTests();
// ChildScenario::add(...) for the child scenarios (TimeKernelTest.cpp).
void registerTimeKernelScenarios();
