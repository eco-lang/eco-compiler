#pragma once

#include "../TestSuite.hpp"

// threaded-gc-01 Step 10: the metadata design scales to a multi-TB old-gen
// reservation without committing memory up front (master plan phase 1 exit).
extern Testing::TestCase testOldGenGeometryAt8TB;
extern Testing::TestCase testOldGenMetadataReserve8TBIsCheap;
