#pragma once

#include "../TestSuite.hpp"

// threaded-gc-05c Part B (plans/threaded-gc-05c-concurrent-marking.md P§3.11):
// heap-relative trigger pacing.
extern Testing::TestCase testPromoRateEwmaDeterministic;
extern Testing::TestCase testOldAllocTotalMonotone;
extern Testing::TestCase testHeadroomTriggerThreshold;
extern Testing::TestCase testHeadroomFiresBeforePressure;
extern Testing::TestCase testPacedLiveBudgetFiresEarlierByHorizon;
extern Testing::TestCase testGarbageBackstop;
extern Testing::TestCase testPacingIgnoresMarkProgress;
