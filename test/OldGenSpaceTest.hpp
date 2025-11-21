#pragma once

#include "TestSuite.hpp"

// OldGenSpace tests
extern Testing::Test testAllocateTLAB;
extern Testing::Test testRootsMarkedAtStart;
extern Testing::Test testRootsPreservedAfterIncrementalMark;
extern Testing::Test testRootsPreservedAfterSweep;
extern Testing::Test testGarbageUnmarkedInIncrementalSteps;
extern Testing::Test testGarbageFreeListedAfterSweep;
