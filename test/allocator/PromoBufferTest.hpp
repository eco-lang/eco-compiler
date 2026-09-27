#pragma once

#include "../TestSuite.hpp"

// threaded-gc-06 Step 4: per-worker promotion buffers (P§3.8, HEAP_054).
extern Testing::TestCase testPromoViaCtxMatchesSerial;
extern Testing::TestCase testWorkerCursorReturnedToFront;
extern Testing::TestCase testLadderUnderMutexAccounting;
