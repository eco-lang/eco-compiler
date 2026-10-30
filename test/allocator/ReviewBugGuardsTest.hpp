/**
 * Expected-fail guards for defects found in the runtime review (cpp-review-bugs.md) that are
 * reproduced but not fixed yet. Each id is "RB-<line>", the entry's line in cpp-review-bugs.md
 * when it was triaged (2026-10-30, before the triage paragraph was added to its summary); the
 * entry's verdict names its guard. See test/XfailGuard.hpp for the convention and
 * ECO_TEST_XFAIL=strict.
 */

#ifndef REVIEW_BUG_GUARDS_TEST_HPP
#define REVIEW_BUG_GUARDS_TEST_HPP

#include "../IsolatedTestRunner.hpp"
#include "../TestSuite.hpp"

// Guards that need no process of their own.
void registerReviewBugGuards(Testing::TestSuite& suite);

// Guards that initialize the allocator: each case runs in a spawned child.
void registerReviewBugIsolatedGuards(IsolatedTestRunner::IsolatedTestCaseSuite& suite);

#endif // REVIEW_BUG_GUARDS_TEST_HPP
