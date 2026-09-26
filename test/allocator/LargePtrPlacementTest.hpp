#pragma once

#include "../TestSuite.hpp"

// threaded-gc-04b (plans/threaded-gc-04b-young-large-objects.md): placement
// of large pointer-bearing objects (nursery or YLOS), never born old.
extern Testing::TestCase testPlaceLargeDecisions;
extern Testing::TestCase testLargePtrConfigJson;
extern Testing::TestCase testLargeArrayInNurseryKeepsChildren;
extern Testing::TestCase testLargeArrayPromotesByCopy;
extern Testing::TestCase testLargeRegionInNursery;
extern Testing::TestCase testYlosChildrenSurviveMinors;
extern Testing::TestCase testYlosAgesAndPromotesInPlace;
extern Testing::TestCase testYlosUnreachableFreedAtMinor;
extern Testing::TestCase testYlosUnreachableFreedAtMajor;
extern Testing::TestCase testYlosReachedOnlyThroughNurseryObject;
extern Testing::TestCase testYlosBuilderNeverAges;
extern Testing::TestCase testYlosReachedTwiceScannedOnce;
extern Testing::TestCase testYlosCensusWriteSiteCaught;
extern Testing::TestCase testYlosCensusPromotedInPlaceRecorded;
extern Testing::TestCase testYlosCensusSurvivorChecked;
extern Testing::TestCase testE1LargeArrayPlacementBench;
