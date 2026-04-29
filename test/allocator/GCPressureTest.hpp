#pragma once

#include "../TestSuite.hpp"

// ============================================================================
// Group A — Allocator-API pressure tests
// ============================================================================
extern Testing::TestCase testNurseryChurnPromotesRootedFraction;
extern Testing::TestCase testMajorGCTriggersAfterPromotionFloodAllocator;
extern Testing::TestCase testOldGenGrowsTowardCapWithoutFailure;
extern Testing::TestCase testCyclicGarbageBetweenGenerations;
extern Testing::TestCase testWriteBarrierIntegrityAcrossGenerations;

// ============================================================================
// Group B — eco_alloc_* runtime tests
// ============================================================================
extern Testing::TestCase testEcoAllocChurnSurvivesManyMinorGCs;
extern Testing::TestCase testEcoAllocClosureCapturesSurviveGC;
extern Testing::TestCase testEcoAllocRecordWithMixedFieldsAfterGC;
extern Testing::TestCase testEcoAllocStringChurnAndPromotion;
extern Testing::TestCase testEcoAllocConsListLongPromotion;
extern Testing::TestCase testEcoAllocCustomManyConstructors;

// ============================================================================
// Group C — Old-gen-focused tests
// ============================================================================
extern Testing::TestCase testOldGenSizeClassChurn;
extern Testing::TestCase testLargeObjectPinnedAcrossMajorGC;
extern Testing::TestCase testFragmentationAndCoalescingAfterRepeatedSweeps;
extern Testing::TestCase testMajorGCInitiatedByOccupancyAndAllocFailure;

// ============================================================================
// Group D — Integration / mixed workload tests
// ============================================================================
extern Testing::TestCase testRandomizedPressureWorkload;
extern Testing::TestCase testRetentionRateSweep;
extern Testing::TestCase testStackRootRangeUnderPressure;
extern Testing::TestCase testSafepointPollingDrainsPressure;

// ============================================================================
// Group E — Adaptive lazy-sweep pacing (plans/dynamic-pressure-aware-sweep.md)
// ============================================================================
extern Testing::TestCase testPanicSweepDrivesAllocationToCompletion;
