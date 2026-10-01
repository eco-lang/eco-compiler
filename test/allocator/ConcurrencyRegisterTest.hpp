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
extern Testing::TestCase testCR018EmptyBlockFlipKeepsLiveCells;    // CR-018 (fixed)
extern Testing::TestCase testCR018Control;                         // CR-018 negative control (hook)
extern Testing::TestCase testCR017RegionT0WalkSkipsFreedCellK1;    // CR-017 (fixed)
extern Testing::TestCase testCR017RegionT0WalkSkipsFreedCellK2;    // CR-017 (fixed)
extern Testing::TestCase testHeap074Tripwire;                      // CR-017 fix: HEAP_074 validate tripwire
extern Testing::TestCase testCR025GangMemberStallInPause;          // CR-025
extern Testing::TestCase testCR029BagRungSizeClassedBitmap;        // CR-029
extern Testing::TestCase testCR029BagRungSizeClassedLegacy;        // CR-029
extern Testing::TestCase testCR014TailShrinkN2;                    // CR-014 A (fixed)
extern Testing::TestCase testCR014TailShrinkN1;                    // CR-014 A (fixed)
extern Testing::TestCase testCR014TailReleasesStashedBlock;        // CR-014 B (fixed)
extern Testing::TestCase testCR014TailReissueDoubleAlloc;          // CR-014 C (fixed)
extern Testing::TestCase testCR001Recount;                         // CR-001 (a) (fixed by CR-018)
extern Testing::TestCase testCR001Release;                         // CR-001 (b) (fixed by CR-018)
extern Testing::TestCase testCR001RecountTail;                     // CR-001 (a, tail) (fixed)
extern Testing::TestCase testCR001ReleaseTail;                     // CR-001 (b, tail) (fixed)
extern Testing::TestCase testCR016FlipChunk;                       // CR-016 (fixed)
extern Testing::TestCase testCR016FlipStash;                       // CR-016 (fixed)
extern Testing::TestCase testCR028V11ParsesPoppedCell;             // CR-028 (fixed, validate)
extern Testing::TestCase testCR037ReusedYlosK1;                    // CR-037 (fixed)
extern Testing::TestCase testCR037ReusedYlosK2;                    // CR-037 (fixed)
extern Testing::TestCase testCR037Control;                         // CR-037 negative control
extern Testing::TestCase testCR017R1YlosIntoGreyedCell;            // CR-017 R1 (fixed)
extern Testing::TestCase testCR017R1Control;                       // CR-017 R1 negative control
extern Testing::TestCase testCR017R1YlosIntoGreyedCellK2;          // CR-017 R1 k=2 (fixed)
extern Testing::TestCase testCR017R1ControlK2;                     // CR-017 R1 k=2 negative control
extern Testing::TestCase testCR017R2MarkOnFreeCell;                // CR-017 R2 (fixed)
extern Testing::TestCase testCR017R2Control;                       // CR-017 R2 negative control
extern Testing::TestCase testCR007PromoMuHelperWait;               // CR-007 (fixed)
extern Testing::TestCase testCR007CapFallback;                     // CR-007 fix: the cap fallback
extern Testing::TestCase testCR023ForeignStopRelaunch;             // CR-023 (xfail)
extern Testing::TestCase testCR012aFinishTrigger;                  // CR-012(a) (won't-fix, opt-in)
extern Testing::TestCase testCR012bFreeList;                       // CR-012(b) (won't-fix, opt-in)
extern Testing::TestCase testCR012cDecommitClock;                  // CR-012(c) (won't-fix, opt-in)
extern Testing::TestCase testCR012dPopulateWindow;                 // CR-012(d) (fixed)
extern Testing::TestCase testCR012Forbid;                          // CR-012 option F: death guard
extern Testing::TestCase testCR012OptIn;                           // CR-012 control: the opt-in
extern Testing::TestCase testCR012Sequential;                      // CR-012 control: sequential mutators
extern Testing::TestCase testCR012dSequential;                     // CR-012 (d) fixed, sequential
extern Testing::TestCase testCR033FreshPageTailParses;             // CR-033 (fixed)
extern Testing::TestCase testCR033Control;                         // CR-033 negative control
extern Testing::TestCase testCR033LegacySweepS1;                   // CR-033 S1 (fixed, legacy)
extern Testing::TestCase testCR033S1Control;                       // CR-033 S1 negative control
extern Testing::TestCase testCR035StaleIndexAtFlip;                // CR-035 (fixed)
extern Testing::TestCase testCR035LostObject;                      // CR-035 (fixed)
extern Testing::TestCase testCR035PreconditionGone;                // CR-035: CR-018 removes its precondition
extern Testing::TestCase testCR036ReissueWitness;                  // CR-036 witness (fixed)
extern Testing::TestCase testCR036Im5SeesReissue;                  // CR-036 IM5 (validate)
extern Testing::TestCase testCR036Im5Control;                      // CR-036 IM5 negative control (validate)
extern Testing::TestCase testCR038DeadYlosSlotIntoRetired;         // CR-038 premise-drift witness (fixed)
extern Testing::TestCase testCR038Control;                         // CR-038 negative control
extern Testing::TestCase testCR039DeadYlosGreysFreedYlos;          // CR-039 (fixed; guard cr038Z)
extern Testing::TestCase testCR039Control;                         // CR-039 negative control
