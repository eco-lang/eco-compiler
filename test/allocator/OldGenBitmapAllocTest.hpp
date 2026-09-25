#pragma once

#include "../TestSuite.hpp"

// threaded-gc-02 Step 10 (plans/threaded-gc-02-bitmap-allocation.md): bitmap
// allocation, gap sweep, sentinel-free body frees, and the demotion lever.
extern Testing::TestCase testBitmapVirginBlockAddressOrder;
extern Testing::TestCase testBitmapReuseDeadCellsAfterMajor;
extern Testing::TestCase testBitmapSplitBeforeVirginW6Rule;
extern Testing::TestCase testBitmapFreeBodyInUniformBlock;
extern Testing::TestCase testBitmapFreeBodyInUnsweptMixedBlock;
extern Testing::TestCase testBitmapGapSweepDemotedBlock;
extern Testing::TestCase testBitmapDetachOnRelease;
extern Testing::TestCase testBitmapDeadBodyRetiredAtMark;
extern Testing::TestCase testDemoteLiveFractionLever;
