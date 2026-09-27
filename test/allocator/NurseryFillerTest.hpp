#pragma once

#include "../TestSuite.hpp"

// threaded-gc-06 Step 1: survivor-prefix fillers and object-byte nursery
// accounting (HEAP_068).
extern Testing::TestCase testFillerSkippedBySurvivorWalk;
extern Testing::TestCase testTriggerCountsObjectBytes;
extern Testing::TestCase testGrowthCountsObjectBytes;
extern Testing::TestCase testFailSoftUsesObjectBytes;
extern Testing::TestCase testAllocEndCappedCounted;
