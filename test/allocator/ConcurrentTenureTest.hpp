#pragma once

#include "../TestSuite.hpp"

// threaded-gc-07 Part B (plans/threaded-gc-07-concurrent-tenuring.md Step 9):
// concurrent tenuring (tenure_mode 2) against its exact oracle (mode 1).
extern Testing::TestCase testTenureStopResumeSameLayout;
extern Testing::TestCase testTenureModesAgreeOnCounters;
extern Testing::TestCase testTenureLateHelpParallel;
extern Testing::TestCase testTenureForkChild;
extern Testing::TestCase testTenureExitWhileRunning;
extern Testing::TestCase testTenureDuringCycle;
extern Testing::TestCase testTenureNegativeControls;
extern Testing::TestCase testTenureBodyRemarkControl;
extern Testing::TestCase testTenureShrinkSkipsGranted;
extern Testing::TestCase testTenureCollectorThreads;
extern Testing::TestCase testTenureRespawnAndForkStorm;
extern Testing::TestCase testTenureFifoOrder;
