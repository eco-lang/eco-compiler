#pragma once

#include "../TestSuite.hpp"

// threaded-gc-03: GC helper pool, PageWork, mode equivalence.
extern Testing::TestCase testHelperConfigValidation;
extern Testing::TestCase testHelperPoolSyncRunsInline;
extern Testing::TestCase testHelperPoolConcurrentRunsOnWorker;
extern Testing::TestCase testHelperPoolFifoAndDrain;
extern Testing::TestCase testHelperPoolStallAccounting;
extern Testing::TestCase testHelperPoolJitterKeepsFifo;
extern Testing::TestCase testHelperPoolStateMachineAsserts;
extern Testing::TestCase testPageWorkReleaseThenCancel;
extern Testing::TestCase testPageWorkDelaySemantics;
extern Testing::TestCase testPageWorkReuseWaitsForPostedDiscard;
extern Testing::TestCase testPageWorkPendingCap;
extern Testing::TestCase testPageWorkReleaseWaitsForOverlappingPopulate;
extern Testing::TestCase testPageWorkFreshBumpWindow;
extern Testing::TestCase testPageWorkSlotFullWaits;
extern Testing::TestCase testPageWorkDrainAllDiscardsPending;
extern Testing::TestCase testPageWorkPopulateUnsupported;
extern Testing::TestCase testDecommitModesAgreeOnCounters;
// plans/frontend-heap-release.md §3.9 (HEAP_076): the explicit release.
extern Testing::TestCase testExplicitReleaseModesAgree;
extern Testing::TestCase testExplicitReleaseReturnsMemory;
extern Testing::TestCase testCommitAheadNeverRemapsWindow;
extern Testing::TestCase testPageWorkValidatorCatchesOwnedTrackedExtent;
extern Testing::TestCase testPageWorkDelayMajors;
extern Testing::TestCase testMmuIncludesHelperStalls;
extern Testing::TestCase testHelperPoolSurvivesFork;
