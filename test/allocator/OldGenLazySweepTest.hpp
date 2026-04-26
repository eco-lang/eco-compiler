#pragma once

#include "../TestSuite.hpp"

// Tests covering the mark-driven live-bytes accounting, all-dead block fast
// path, lazy-sweep wiring, post-mark shrink, and compaction-during-sweep
// guard introduced by plans/gc-mark-driven-live-lazy-sweep.md.

extern Testing::TestCase testAllDeadBlockReclaimSkipsCells;
extern Testing::TestCase testLazySweepDrivenFromAllocation;
extern Testing::TestCase testShrinkUsesMarkLiveBytes;
extern Testing::TestCase testCompactionBlockedDuringSweep;
extern Testing::TestCase testPageIndexBlockLookup;
