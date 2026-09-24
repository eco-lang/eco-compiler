#pragma once

#include "../TestSuite.hpp"

// threaded-gc-00 (plans/threaded-gc-00-measure-and-fix.md Step 8): pause
// percentiles, MMU, and the merge of pause logs across GCStats objects.
extern Testing::TestCase testGCPauseStatsMMU;
extern Testing::TestCase testGCPauseStatsPercentiles;
extern Testing::TestCase testGCPauseStatsCombine;
