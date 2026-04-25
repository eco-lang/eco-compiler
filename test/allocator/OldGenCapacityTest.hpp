#pragma once

#include "../TestSuite.hpp"

// Old-gen capacity-shrink + large/pinned page reuse coverage.
// See plans/oldgen-capacity-shrink-and-large-reuse.md for the implementation
// plan these tests verify.

extern Testing::TestCase testCapacityShrinksAfterMajorGC;
extern Testing::TestCase testLargeBlockReuseSameAddress;
extern Testing::TestCase testEmptyPageConvertedToLarge;
extern Testing::TestCase testShrinkHysteresisGuard;
extern Testing::TestCase testShrinkHonorsFloor;
extern Testing::TestCase testUnassignedBlocksShrink;
extern Testing::TestCase testDecommitFlagPathExercised;
