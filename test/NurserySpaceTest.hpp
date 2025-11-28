#pragma once

#include "TestSuite.hpp"

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
