#pragma once

#include "../IsolatedTestRunner.hpp"

// SD-1 (plans/review-bug-list-fixes.md): 16-bit process ids wrap and collide in the
// Scheduler's id-keyed tables; finished processes stay rooted.
void registerSchedulerPidTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
