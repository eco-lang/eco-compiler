// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test for SCF lowering infrastructure.
// Currently the SCF lowering patterns are limited:
// - eco.case with pure returns (no eco.jump) can potentially lower to scf.if
// - Joinpoints marked as SCF-candidates can potentially lower to scf.while
// Most patterns still go through CF lowering path in EcoToLLVM.
//
// This test verifies that the new passes (JoinpointNormalizationPass,
// EcoControlFlowToSCFPass) don't break existing functionality.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c42 = arith.constant 42 : i64
    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value

    // Test 1: Simple case dispatch (currently CF-lowered)
    // Tag 0 = "Left", Tag 1 = "Right"
    %left = eco.construct(%b1) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %right = eco.construct(%b2) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Case on left variant
    eco.case %left [0, 1] {
      %p = eco.project %left[0] : !eco.value -> !eco.value
      eco.dbg %p : !eco.value
      eco.return
    }, {
      eco.dbg %c42 : i64
      eco.return
    }
    // CHECK: 1

    // Case on right variant
    eco.case %right [0, 1] {
      eco.dbg %c1 : i64
      eco.return
    }, {
      %p = eco.project %right[0] : !eco.value -> !eco.value
      eco.dbg %p : !eco.value
      eco.return
    }
    // CHECK: 2

    // Test 2: Simple joinpoint (looping pattern, currently CF-lowered)
    // This is the canonical list fold pattern
    eco.joinpoint 0(%val: !eco.value) {
      // Get the tag to decide continue/exit
      %tag = eco.get_tag %val : !eco.value -> i32
      %c0_i32 = arith.constant 0 : i32
      %isNil = arith.cmpi eq, %tag, %c0_i32 : i32

      eco.case %val [0, 1] {
        // Base case: Nil - just return
        eco.dbg %c1 : i64
        eco.return
      }, {
        // Cons case: recurse on tail
        %tail = eco.project %val[1] : !eco.value -> !eco.value
        eco.jump 0(%tail : !eco.value)
      }
      eco.return
    } continuation {
      // Create a simple list: Cons(1, Cons(2, Nil))
      %nil = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
      %cons2 = eco.construct(%b2, %nil) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
      %cons1 = eco.construct(%b1, %cons2) {tag = 1 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
      eco.jump 0(%cons1 : !eco.value)
    }
    // CHECK: 1

    // Test 3: Verify get_tag works with tags > 1
    %custom = eco.construct(%b1) {tag = 5 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag5 = eco.get_tag %custom : !eco.value -> i32
    %tag5_64 = arith.extui %tag5 : i32 to i64
    eco.dbg %tag5_64 : i64
    // CHECK: 5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
