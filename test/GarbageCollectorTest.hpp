#pragma once

#include "TestSuite.hpp"

// Full GarbageCollector tests (minor + major GC)
extern Testing::Test testPromotionToOldGen;
extern Testing::Test testMinorThenMajorGCSequence;
extern Testing::Test testLongLivedObjectsSurviveMajorGC;
extern Testing::Test testMajorGCReclaimsOldGenGarbage;
extern Testing::Test testFullGCCycleWithCompaction;
extern Testing::Test testMixedAllocationWorkload;
extern Testing::Test testObjectGraphSpanningPromotions;
extern Testing::Test testMultipleMajorGCCycles;
extern Testing::Test testStressTestBothGenerations;
