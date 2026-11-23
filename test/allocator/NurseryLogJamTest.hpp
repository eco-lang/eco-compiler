#pragma once

#include "../TestSuite.hpp"

// plans/jsonlargearray-nursery-oom-under-pressure.md, HEAP_087: a minor that leaves survivors near the
// nursery's threshold must not leave eden too small for the largest object the nursery accepts.
extern Testing::TestCase testNurseryLogJamRegion;
extern Testing::TestCase testNurseryLogJamLegacy;
extern Testing::TestCase testNurseryReserveRule;
