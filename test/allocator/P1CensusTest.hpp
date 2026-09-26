#pragma once

#include "../TestSuite.hpp"

// threaded-gc-04: P1 census + the S1/S2 hazards.
extern Testing::TestCase testP1CensusModeParsing;
extern Testing::TestCase testP1OldGenCatchesWriteAfterPromotion;
extern Testing::TestCase testP1OldGenNoFalsePositiveAcrossMajors;
extern Testing::TestCase testP1OldGenPruneDropsDead;
extern Testing::TestCase testP1OldGenCompactionInvalidates;
extern Testing::TestCase testP1WriteSiteFreshIsLegal;
extern Testing::TestCase testP1WriteSiteAgedCaught;
extern Testing::TestCase testP1WriteSiteBuilderExempt;
extern Testing::TestCase testP1ChunkChainSurvivesMidConstructionGC;
