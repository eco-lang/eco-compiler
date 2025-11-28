#pragma once

#include "TestSuite.hpp"

// OldGenSpace tests - mark and sweep, allocation
extern Testing::TestCase testOldGenAllocate;
extern Testing::TestCase testRootsMarkedAtStart;
extern Testing::TestCase testRootsPreservedAfterIncrementalMark;
extern Testing::TestCase testRootsPreservedAfterSweep;
extern Testing::TestCase testGarbageUnmarkedInIncrementalSteps;
extern Testing::TestCase testGarbageReclaimedAfterSweep;

// Phase 1-2 tests: Free-list allocation
extern Testing::TestCase testSizeClassCorrectness;
extern Testing::TestCase testFreeListRoundTrip;
extern Testing::TestCase testMixedSizeAllocation;

// Phase 3 tests: Lazy sweeping
extern Testing::TestCase testLazySweepPreservesLive;
extern Testing::TestCase testSweepProgressMonotonicity;
extern Testing::TestCase testAllocationDuringSweep;

// Phase 4 tests: Incremental marking
extern Testing::TestCase testIncrementalMarkEquivalence;
extern Testing::TestCase testMarkingWithAllocation;

// Phase 5 tests: Fragmentation statistics
extern Testing::TestCase testUtilizationCalculation;
extern Testing::TestCase testLiveBytesAccuracy;

// Phase 6 tests: Incremental compaction
extern Testing::TestCase testEvacuationPreservesValues;
extern Testing::TestCase testForwardingPointerCorrectness;

// Integration / Stress tests
extern Testing::TestCase testMultipleCycleStability;
extern Testing::TestCase testHeaderConsistency;
extern Testing::TestCase testEmptyHeapBehavior;
extern Testing::TestCase testAllGarbageHeap;
extern Testing::TestCase testAllLiveHeap;
