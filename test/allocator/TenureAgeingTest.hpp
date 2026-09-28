#pragma once

#include "../TestSuite.hpp"

// threaded-gc-07b (plans/threaded-gc-07b-tenure-ageing.md Step 8): tenure age
// k > 1 in the region nursery (in-place ageing, the ageing mark, the zap).
extern Testing::TestCase testAgeOracleLegacy;
extern Testing::TestCase testAgeLifetime;
extern Testing::TestCase testAgeNoNepotismAndZap;
extern Testing::TestCase testAgeHealThroughMark;
extern Testing::TestCase testAgeYoungLarge;
extern Testing::TestCase testAgeModesAgree;
extern Testing::TestCase testAgeLateHelpParallel;
extern Testing::TestCase testAgeNegativeControls;
