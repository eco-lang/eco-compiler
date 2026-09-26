#pragma once

#include "../TestSuite.hpp"

// threaded-gc-05a (plans/threaded-gc-05a-incremental-marking.md): the
// incremental mark cycle (HEAP_063) — t0 snapshot, paced slices, fixed
// schedule, allocate-black, deferred frees, joins, validators.
extern Testing::TestCase testIncrConfigJson;
extern Testing::TestCase testPauseKindsCounted;
extern Testing::TestCase testIncrT0MatchesStwLiveSet;
extern Testing::TestCase testIncrT0YlosCellMarked;
extern Testing::TestCase testIncrT0BuilderChildrenSurvive;
extern Testing::TestCase testIncrScheduleFixed;
extern Testing::TestCase testIncrOldReachableOnlyFromSurvivor;
extern Testing::TestCase testIncrRootOverwrittenAfterT0;
extern Testing::TestCase testIncrExternalStoreOverwrittenAfterT0;
extern Testing::TestCase testIncrAllocateBlackEveryEntryPoint;
extern Testing::TestCase testIncrNoPreT0UniformReuse;
extern Testing::TestCase testIncrTriggersSuppressed;
extern Testing::TestCase testIncrLiveBudgetUsesTracedLive;
extern Testing::TestCase testIncrBuilderFilledDuringCycle;
extern Testing::TestCase testIncrDeferredBodyFree;
extern Testing::TestCase testIncrDeferredYlosFree;
extern Testing::TestCase testIncrYlosPromotedInPlaceDuringCycle;
extern Testing::TestCase testIncrNoReleaseDuringCycle;
extern Testing::TestCase testIncrJoinOnExplicitMajor;
extern Testing::TestCase testIncrJoinOnYlosAllocFailure;
extern Testing::TestCase testIncrPressureFinish;
extern Testing::TestCase testIncrResetMidCycle;
extern Testing::TestCase testIncrNegativeSkipYoungWalk;
extern Testing::TestCase testIncrNegativeSkipExternal;
extern Testing::TestCase testIncrNegativeSkipAllocateBlack;
