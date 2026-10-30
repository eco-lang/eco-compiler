/**
 * Regression tests for defects found in the runtime review (cpp-review-bugs.md), written as
 * expected-fail guards (test/XfailGuard.hpp) before the fixes and turned into plain tests when the
 * defects were fixed (plans/review-likely-bugs-fixes.md, 2026-10-30). Each id is "RB-<line>", the
 * entry's line in cpp-review-bugs.md when it was triaged; the entry's verdict names its test.
 */

#ifndef REVIEW_BUG_GUARDS_TEST_HPP
#define REVIEW_BUG_GUARDS_TEST_HPP

#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"

// Tests that need no process of their own.
void registerReviewBugGuards(Testing::TestSuite& suite);

// Tests that initialize the allocator: each case runs in a spawned child.
void registerReviewBugIsolatedGuards(IsolatedTestRunner::IsolatedTestCaseSuite& suite);

#endif // REVIEW_BUG_GUARDS_TEST_HPP
