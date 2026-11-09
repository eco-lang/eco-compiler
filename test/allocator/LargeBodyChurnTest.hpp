#pragma once

#include "../TestSuite.hpp"

// GC triggers for large-body allocation (plans/large-body-gc-trigger.md):
// direct old-gen allocation debt requests minors (D1-D3), and a failed split
// body allocation recovers with a minor then a major (D4). And the deferred-bytes finish of a running mark
// cycle (plans/large-body-deferral-pacing.md, HEAP_084).

extern Testing::TestCase testLargeBodyChurnRunsMinors;
extern Testing::TestCase testLargeBodyPromotedGarbageRunsMajors;
extern Testing::TestCase testLargeBodyRecoveryWithoutBudget;
extern Testing::TestCase testLargeBodyBudgetZeroIsOff;
extern Testing::TestCase testDirectAllocMinorBudgetConfig;
extern Testing::TestCase testDeferredFinishBoundsCycle;
extern Testing::TestCase testDeferredFinishDeterministic;
extern Testing::TestCase testDeferredFinishConfig;
