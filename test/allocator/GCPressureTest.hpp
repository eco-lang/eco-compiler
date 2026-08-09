#pragma once

#include "../TestSuite.hpp"

// ============================================================================
// Group A — Allocator-API pressure tests
// ============================================================================
extern Testing::TestCase testNurseryChurnPromotesRootedFraction;
extern Testing::TestCase testMajorGCTriggersAfterPromotionFloodAllocator;
extern Testing::TestCase testOldGenGrowsTowardCapWithoutFailure;
extern Testing::TestCase testCyclicGarbageBetweenGenerations;
// NOTE: testWriteBarrierIntegrityAcrossGenerations was REMOVED 2026-08-09.
// It raw-stored nursery HPointers into a promoted old-gen Record and then
// asserted the GC kept them alive — a heap state compiled Elm cannot produce
// (values are immutable, so an old object never acquires a younger pointer),
// which is precisely why the design carries no write barrier and no
// remembered set and minor GC never scans old gen for roots. It only ever
// "passed" in non-validate builds because the freed bytes happened to still
// read back correctly; ECO_HEAP_VALIDATE's from-space poisoning exposed it.
// Do not reinstate it without first adding a remembered set.

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
