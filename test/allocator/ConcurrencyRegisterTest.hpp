#pragma once

#include "../TestSuite.hpp"

// Regression guards for entries of plans/threaded-gc-concurrency-register.md
// that need a unit test (the entry's id is in each test name, so
// `--filter CR-0NN` runs one guard).
//
// Expected-fail guards ("[xfail CR-0NN]" in the name) reproduce a defect that
// is not fixed yet. Each runs its scenario in a forked child. By default the
// test PASSES while the defect reproduces (XFAIL) and FAILS when it does not
// (XPASS: the entry looks fixed, or the scenario no longer reaches it: turn the
// guard into a plain test in the fixing change). ECO_TEST_XFAIL=strict makes
// each guard assert the fixed behaviour instead, so it fails on today's code:
//
//   ECO_TEST_XFAIL=strict build/test/test --filter "xfail CR-"

extern Testing::TestCase testForwardWordMatchesBitfields;          // CR-011
extern Testing::TestCase testCR018EmptyBlockFlipKeepsLiveCells;    // CR-018 (xfail)
extern Testing::TestCase testCR017RegionT0WalkSkipsFreedCellK1;    // CR-017 (xfail)
extern Testing::TestCase testCR017RegionT0WalkSkipsFreedCellK2;    // CR-017 (xfail)
extern Testing::TestCase testCR025GangMemberStallInPause;          // CR-025
extern Testing::TestCase testCR029BagRungSizeClassedBitmap;        // CR-029
extern Testing::TestCase testCR029BagRungSizeClassedLegacy;        // CR-029
