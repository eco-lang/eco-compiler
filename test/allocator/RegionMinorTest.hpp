#pragma once

#include "../TestSuite.hpp"

// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md): the region
// nursery (HEAP_069) and the tenure job (HEAP_070).
extern Testing::TestCase testRegionConfigValidation;
extern Testing::TestCase testRegionGeometry;
extern Testing::TestCase testRegionLegacyGeometryUnchanged;
extern Testing::TestCase testRegionObjectsMatchLegacy;
extern Testing::TestCase testRegionLongListTenured;
extern Testing::TestCase testRegionRootResolve;
extern Testing::TestCase testRegionEveryTagTenured;
extern Testing::TestCase testRegionBuilderStaysInArea;
extern Testing::TestCase testRegionLargeBodies;
extern Testing::TestCase testRegionYlosGenerations;
extern Testing::TestCase testRegionRetentionBound;
extern Testing::TestCase testRegionStwMajorBetweenMinors;
extern Testing::TestCase testParallelTenureObjectsEqualExact;
extern Testing::TestCase testRegionParallelSuite;
extern Testing::TestCase testRegionT0CoversTenuring;
