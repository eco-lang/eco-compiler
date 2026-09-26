#pragma once

#include "../TestSuite.hpp"

// threaded-gc-05b (plans/threaded-gc-05b-parallel-marking.md): parallel
// marking (HEAP_064) -- entry encoding, deque, gang, chunking, exact tickets,
// determinism across marker counts, negative controls.
extern Testing::TestCase testMarkEntryEncoding;
extern Testing::TestCase testDequeLifoOwnerFifoThief;
extern Testing::TestCase testDequeGrowKeepsEntries;
extern Testing::TestCase testGangRunsEveryMemberOnce;
extern Testing::TestCase testGangForkChild;
extern Testing::TestCase testMarkThreadsConfig;
extern Testing::TestCase testMarkChunkedArrayAllChildren;
extern Testing::TestCase testMarkChunkedListBacking;
extern Testing::TestCase testMarkChunkBudgetSplitsArray;
extern Testing::TestCase testParMarkMatchesSerial;
extern Testing::TestCase testParMarkUnitsExactPerSlice;
extern Testing::TestCase testParMarkDeterministicAcrossThreadCounts;
extern Testing::TestCase testParMarkResumesAcrossSlices;
extern Testing::TestCase testParMarkStealingHappens;
extern Testing::TestCase testParMarkIncrementalOffUsesT0Cycle;
extern Testing::TestCase testParMarkJoinDrainParallel;
extern Testing::TestCase testParMarkAutoThreadCount;
extern Testing::TestCase testParMarkNegativeSkipMergeWorker1;
extern Testing::TestCase testParMarkNegativePlainBits;
extern Testing::TestCase testParMarkNegativeStealWithoutTicket;
