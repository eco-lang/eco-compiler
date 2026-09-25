#pragma once

#include "../TestSuite.hpp"

// threaded-gc-01 Steps 3/4: never-moving storage and stable block ids.
extern Testing::TestCase testReservedArrayStableAndZeroed;
extern Testing::TestCase testReservedArrayDiscardZeroes;
extern Testing::TestCase testReservedArrayHugeGranule;
extern Testing::TestCase testReservedArrayScaleReserveIsCheap;
extern Testing::TestCase testBlockTableOrderMatchesVectorModel;
extern Testing::TestCase testBlockTableIdsStable;
extern Testing::TestCase testBlockTableBeyond65536;
extern Testing::TestCase testBlockTableClearRestartsIds;
