#pragma once

#include "../TestSuite.hpp"

// threaded-gc-06 (plans/threaded-gc-06-parallel-minor.md): parallel minor GC
// (HEAP_067) and its configuration.
extern Testing::TestCase testMinorThreadsConfigParse;
extern Testing::TestCase testGangSizedForMinorAndMark;
extern Testing::TestCase testEngineMatchesSerialObjectCounters;
extern Testing::TestCase testEngineLongListRuns;
extern Testing::TestCase testEngineSharedTailList;
extern Testing::TestCase testEngineChunkedArray;
extern Testing::TestCase testEngineLargeBodies;
extern Testing::TestCase testEngineBuilderStaysYoung;
extern Testing::TestCase testParMinorStealing;
extern Testing::TestCase testParMinorFallbackSpace;
extern Testing::TestCase testParMinorFallbackSmall;
extern Testing::TestCase testParMinorFillersParse;
extern Testing::TestCase testParMinorForkChild;
extern Testing::TestCase testParMinorNegativeControls;
extern Testing::TestCase testParMinorDuringCycle;
