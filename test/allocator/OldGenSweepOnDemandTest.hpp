#pragma once

#include "../TestSuite.hpp"

// Tests covering the sweep-on-demand allocation path introduced by
// plans/sweep-on-demand-allocation.md. Layered on top of mark-driven lazy
// sweep: every allocation slow path drives sweep before it consumes a fresh
// bag page or grows committed capacity.

extern Testing::TestCase testSweepBeforeGrow;
extern Testing::TestCase testPerAllocSweepCap;
extern Testing::TestCase testPendingBlocksCounterTracksFullySwept;
extern Testing::TestCase testMidCycleBlockReleaseDecrementsCounter;
