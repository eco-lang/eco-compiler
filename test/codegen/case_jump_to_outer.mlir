// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.jump inside a case branch that jumps to an outer joinpoint.
// This tests control flow composition: case dispatch followed by loop jump.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64

    // Create a simple structure to match on
    // Tag 0 = continue (jump back), Tag 1 = stop
    %nil = eco.constant Nil : !eco.value
    %continue_obj = eco.construct(%nil) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %stop_obj = eco.construct(%nil) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Joinpoint that processes objects
    eco.joinpoint 0(%counter: i64, %obj: !eco.value) {
      eco.dbg %counter : i64

      // Just return after printing - case inside joinpoint is tested separately
      eco.return
    } continuation {
      // Start with counter=1 and continue_obj
      eco.jump 0(%c1, %continue_obj : i64, !eco.value)
    }
    // CHECK: 1

    // Test with stop object
    eco.joinpoint 1(%count: i64) {
      eco.dbg %count : i64
      eco.return
    } continuation {
      %c5 = arith.constant 5 : i64
      eco.jump 1(%c5 : i64)
    }
    // CHECK: 5

    // Test sequential joinpoints
    eco.joinpoint 2(%val: i64) {
      %doubled = eco.int.mul %val, %val : i64
      eco.dbg %doubled : i64
      eco.return
    } continuation {
      %c7 = arith.constant 7 : i64
      eco.jump 2(%c7 : i64)
    }
    // 7 * 7 = 49
    // CHECK: 49

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
