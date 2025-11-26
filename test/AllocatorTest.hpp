#pragma once

#include "TestSuite.hpp"

// Full Allocator tests (minor + major GC).
extern Testing::TestCase testPromotionToOldGen;
extern Testing::TestCase testMinorThenMajorGCSequence;
extern Testing::TestCase testLongLivedObjectsSurviveMajorGC;
extern Testing::TestCase testMajorGCReclaimsOldGenGarbage;
extern Testing::TestCase testFullGCCycle;
extern Testing::TestCase testMixedAllocationWorkload;
extern Testing::TestCase testObjectGraphSpanningPromotions;
extern Testing::TestCase testMultipleMajorGCCycles;
extern Testing::TestCase testStressTestBothGenerations;
