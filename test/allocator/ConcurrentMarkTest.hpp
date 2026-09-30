#pragma once

#include "../TestSuite.hpp"

// threaded-gc-05c (plans/threaded-gc-05c-concurrent-marking.md): concurrent
// marking (HEAP_065) -- the background gang, configuration, the cycle driver
// in modes 1 and 2, determinism across modes, and the negative controls.
extern Testing::TestCase testBgGangLaunchJoinEveryMemberOnce;
extern Testing::TestCase testBgGangStopAndJoinBounded;
extern Testing::TestCase testBgGangPriorityApplied;
extern Testing::TestCase testBgGangForkWhileRunning;
extern Testing::TestCase testBgGangDestructorStops;
extern Testing::TestCase testConcMarkConfigJson;
extern Testing::TestCase testConcMarkEnvOverrides;
extern Testing::TestCase testConcMarkThreadsResolution;
extern Testing::TestCase testConcMarkMatchesPauseMark;
extern Testing::TestCase testConcMarkRunsDuringMinorGCs;
extern Testing::TestCase testConcMarkUnitsExactAcrossB;
extern Testing::TestCase testConcMarkAssistWhenLate;
extern Testing::TestCase testConcMarkClosingJoinsRunningEpisode;
extern Testing::TestCase testConcMarkNoAssistWhenOnTime;
extern Testing::TestCase testConcMarkStoppedEpisodeRelaunches;
extern Testing::TestCase testConcMarkJoinOnExplicitMajor;
extern Testing::TestCase testConcMarkPressureFinish;
extern Testing::TestCase testConcMarkResetMidEpisode;
extern Testing::TestCase testConcMarkForkDuringEpisode;
extern Testing::TestCase testConcMarkSyncModeMarksAtT0;
extern Testing::TestCase testConcMarkT0DistributesToBackground;
extern Testing::TestCase testConcMarkIncrementalOffNoBackground;
extern Testing::TestCase testConcMarkNegativeSkipBgMerge;
extern Testing::TestCase testConcMarkNegativeLeavePrivate;
extern Testing::TestCase testConcMarkNegativeCursorT0Block;
extern Testing::TestCase testConcMarkNegativePlainAllocateBlack;
extern Testing::TestCase testConcMarkNegativeAssistResetsBgCounter;   // IM14 per slot (CR-010)
extern Testing::TestCase testConcMarkScaleBench;
