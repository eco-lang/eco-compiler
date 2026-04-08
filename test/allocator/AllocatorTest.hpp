#pragma once

#include "../TestSuite.hpp"

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

// ByteBuffer / ElmArray survival across major GC.
extern Testing::TestCase testSmallByteBufferSurvivesMajorGCWhenRooted;
extern Testing::TestCase testSmallByteBufferReclaimedWhenUnreachable;
extern Testing::TestCase testSmallElmArraySurvivesMajorGCWhenRooted;
extern Testing::TestCase testSmallElmArrayReclaimedWhenUnreachable;
extern Testing::TestCase testLargeByteBufferSurvivesMajorGCWhenRooted;
extern Testing::TestCase testLargeByteBufferReclaimedWhenUnreachable;
extern Testing::TestCase testLargeElmArraySurvivesMajorGCWhenRooted;
extern Testing::TestCase testLargeElmArrayReclaimedWhenUnreachable;
