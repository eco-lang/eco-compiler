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

// Split-header (HEAP_026) tests: large strings/byte buffers use
// Tag_LargeStringHeader/Tag_LargeByteHeader in nursery + body in old gen.
extern Testing::TestCase testLargeStringSplitHeaderLayout;
extern Testing::TestCase testLargeByteSplitHeaderLayout;
extern Testing::TestCase testSplitBodySurvivesMinorGCWithoutCopy;
extern Testing::TestCase testSplitBodyEarlyReclamationOnDeadHeader;
extern Testing::TestCase testSplitPromotionTransfersOwnership;
extern Testing::TestCase testSplitPromotedBodyReclaimedByMajorGC;
extern Testing::TestCase testSplitThresholdBoundary;
extern Testing::TestCase testSplitStressBoundedOldGenGrowth;
