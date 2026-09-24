#pragma once

#include "../TestSuite.hpp"

// NurserySpace (minor GC) property-based tests
extern Testing::TestCase testMinorGCPreservesRoots;
extern Testing::TestCase testMultipleMinorGCCycles;
extern Testing::TestCase testContinuousGarbageAllocation;

// List locality optimization tests (two-pass spine copying vs BFS)
extern Testing::TestCase testListSurvivesGCWithHybridDFS;
extern Testing::TestCase testListSurvivesGCWithBFS;
extern Testing::TestCase testMultipleListsSurviveGCWithHybridDFS;
extern Testing::TestCase testMultipleListsSurviveGCWithBFS;
extern Testing::TestCase testListLocalityImprovedByHybridDFS;
extern Testing::TestCase testListSurvivesMultipleGCCyclesWithHybridDFS;
extern Testing::TestCase testListSurvivesMultipleGCCyclesWithBFS;
extern Testing::TestCase testDeepListLocalityCopying;

#if ECO_HEAP_VALIDATE
// threaded-gc-00 Step 11: survivor-write census
extern Testing::TestCase testSurvivorWriteCensus;
#endif

// Regression: promoted boxed Ints vs the ECO_HEAP_VALIDATE old-gen walk
extern Testing::UnitTest testPromotedBoxedIntsValidateWalk;
