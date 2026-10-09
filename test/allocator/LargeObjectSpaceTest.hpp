#pragma once

#include "../TestSuite.hpp"

// The large-object space's free-space manager (plans/large-object-space.md D2).
extern Testing::TestCase testLosCoalescesBothNeighbours;
extern Testing::TestCase testLosBestFitAndExactReuse;
extern Testing::TestCase testLosPageAlignsPageMultiples;
extern Testing::TestCase testLosPoolsNeverShareABlock;
extern Testing::TestCase testLosEmptyBlocksAndRemoval;
extern Testing::TestCase testLosRandomChurnMatchesShadow;
extern Testing::TestCase testLosPlacementOfEveryLargeKind;
extern Testing::TestCase testLosChunkChurnReusesBlocks;
extern Testing::TestCase testLosHeaderlessForwardingHazard;
extern Testing::TestCase testLosHeaderless64KiBChunkIsExact;
