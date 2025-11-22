#pragma once

#include "TestSuite.hpp"

// OldGenSpace tests.
extern Testing::UnitTest testAllocateTLAB;
extern Testing::TestCase testRootsMarkedAtStart;
extern Testing::TestCase testRootsPreservedAfterIncrementalMark;
extern Testing::TestCase testRootsPreservedAfterSweep;
extern Testing::TestCase testGarbageUnmarkedInIncrementalSteps;
extern Testing::TestCase testGarbageFreeListedAfterSweep;
