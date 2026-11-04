#pragma once

#include "../IsolatedTestRunner.hpp"

// The WaitService's reaping of a child process whose exit is queued but not popped. Starts the
// Scheduler and the wait thread: spawned child.
void registerWaitServiceTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
