#pragma once

#include "../IsolatedTestRunner.hpp"

// TimerService::schedule with delays that do not fit its clock (NaN, +-inf, +-1e300). Starts the
// Scheduler and the timer thread: spawned child.
void registerTimerServiceTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
