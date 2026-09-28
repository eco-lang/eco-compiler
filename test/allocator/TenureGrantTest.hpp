#pragma once

#include "../TestSuite.hpp"

// threaded-gc-07 Step 4 (plans/threaded-gc-07-concurrent-tenuring.md P§3.12):
// the promotion grant (HEAP_070).
extern Testing::TestCase testGrantCoversCounts;
extern Testing::TestCase testGrantReturnToFront;
extern Testing::TestCase testGrantAccountingMerge;
extern Testing::TestCase testShrinkSkipsGranted;
