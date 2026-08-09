#pragma once

#include "../TestSuite.hpp"

// Capacity-check hoisting: the ensure primitive (HEAP_041,
// plans/capacity-check-hoisting.md §4 Step 2).
extern Testing::TestCase testEnsureHeadroomPostconditionAcrossAdvanceAndGC;
extern Testing::TestCase testEnsureAtClampedBlockGCsInsteadOfAdvancing;
extern Testing::TestCase testEnsureFailSoftTinyConfigTerminates;
extern Testing::TestCase testEnsureAbandonedTailsSurviveValidateWalk;
