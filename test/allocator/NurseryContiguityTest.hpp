#pragma once

#include "../TestSuite.hpp"

// Contiguous nursery extents + the slice layer (HEAP_042,
// plans/contiguous-nursery-space.md §4 Step 2).
extern Testing::TestCase testNurseryExtentsAreContiguousAndMirrored;
extern Testing::TestCase testNurseryGrowthExtendsInPlaceAndSurvivesGC;
extern Testing::TestCase testNurserySliceReleaseRetainsCommitAcrossReacquire;
extern Testing::TestCase testNurserySliceGeometryRebuiltOnReconfigure;
extern Testing::TestCase testNurseryAllocEndFailSoftWhenSurvivorsPastThreshold;
