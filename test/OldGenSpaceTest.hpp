#pragma once

#include "TestSuite.hpp"

// OldGenSpace tests - mark and sweep, allocation
extern Testing::TestCase testOldGenAllocate;
extern Testing::TestCase testRootsMarkedAtStart;
extern Testing::TestCase testRootsPreservedAfterIncrementalMark;
extern Testing::TestCase testRootsPreservedAfterSweep;
extern Testing::TestCase testGarbageUnmarkedInIncrementalSteps;
extern Testing::TestCase testGarbageReclaimedAfterSweep;
