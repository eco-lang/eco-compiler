#pragma once

#include "../TestSuite.hpp"

// Tests for the small-class block budget (plans/small-class-block-budget.md):
// while small_class_bytes_ is below small_class_heap_budget_bytes, small-class
// allocations prefer pulling a fresh uniform bag page over splitting larger
// free cells.

extern Testing::TestCase testSmallClassBudgetUnderCapPullsFreshPages;
extern Testing::TestCase testSmallClassBudgetExhaustedResumesSplitting;
extern Testing::TestCase testSmallClassAboveCapClassesUnaffected;
extern Testing::TestCase testSmallClassBudgetDisabledMatchesLegacy;
extern Testing::TestCase testSmallClassBudgetDebitsOnRelease;
extern Testing::TestCase testSmallClassBudgetIgnoresHeapBasePage;
