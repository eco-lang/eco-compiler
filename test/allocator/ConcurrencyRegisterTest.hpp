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
extern Testing::TestCase testCR014TailShrinkN2;                    // CR-014 A (xfail)
extern Testing::TestCase testCR014TailShrinkN1;                    // CR-014 A (xfail)
extern Testing::TestCase testCR014TailReleasesStashedBlock;        // CR-014 B (xfail)
extern Testing::TestCase testCR014TailReissueDoubleAlloc;          // CR-014 C (xfail)
extern Testing::TestCase testCR001Recount;                         // CR-001 (a) (xfail)
extern Testing::TestCase testCR001Release;                         // CR-001 (b) (xfail)
extern Testing::TestCase testCR016FlipChunk;                       // CR-016 (xfail)
extern Testing::TestCase testCR016FlipStash;                       // CR-016 (xfail)
extern Testing::TestCase testCR028V11ParsesPoppedCell;             // CR-028 (xfail, validate)
extern Testing::TestCase testCR037ReusedYlosK1;                    // CR-037 (xfail)
extern Testing::TestCase testCR037ReusedYlosK2;                    // CR-037 (xfail)
extern Testing::TestCase testCR037Control;                         // CR-037 negative control
extern Testing::TestCase testCR017R1YlosIntoGreyedCell;            // CR-017 R1 (xfail)
extern Testing::TestCase testCR017R1Control;                       // CR-017 R1 negative control
extern Testing::TestCase testCR017R1YlosIntoGreyedCellK2;          // CR-017 R1 k=2 (xfail)
extern Testing::TestCase testCR017R1ControlK2;                     // CR-017 R1 k=2 negative control
extern Testing::TestCase testCR017R2MarkOnFreeCell;                // CR-017 R2 (xfail)
extern Testing::TestCase testCR017R2Control;                       // CR-017 R2 negative control
extern Testing::TestCase testCR007PromoMuHelperWait;               // CR-007 (xfail)
extern Testing::TestCase testCR023ForeignStopRelaunch;             // CR-023 (xfail)
extern Testing::TestCase testCR012aFinishTrigger;                  // CR-012(a) (xfail)
extern Testing::TestCase testCR012bFreeList;                       // CR-012(b) (xfail)
extern Testing::TestCase testCR012cDecommitClock;                  // CR-012(c) (xfail)
extern Testing::TestCase testCR012dPopulateWindow;                 // CR-012(d) (xfail)
extern Testing::TestCase testCR033FreshPageTailParses;             // CR-033 (xfail)
extern Testing::TestCase testCR033Control;                         // CR-033 negative control
extern Testing::TestCase testCR033LegacySweepS1;                   // CR-033 S1 (xfail, legacy)
extern Testing::TestCase testCR033S1Control;                       // CR-033 S1 negative control
extern Testing::TestCase testCR035StaleIndexAtFlip;                // CR-035 (xfail)
extern Testing::TestCase testCR035LostObject;                      // CR-035 (xfail)
extern Testing::TestCase testCR036ReissueWitness;                  // CR-036 witness (xfail)
extern Testing::TestCase testCR038DeadYlosSlotIntoRetired;         // CR-038 premise-drift witness (xfail)
extern Testing::TestCase testCR038Control;                         // CR-038 negative control
