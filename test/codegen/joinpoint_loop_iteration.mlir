// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test additional eco.joinpoint and eco.jump scenarios.
// Note: joinpoint body must be a single block.

module {
  func.func @main() -> i64 {
    %c0 = arith.constant 0 : i64
    %c1 = arith.constant 1 : i64
    %c5 = arith.constant 5 : i64
    %c42 = arith.constant 42 : i64

    // Test 1: Simple value pass-through
    eco.joinpoint 0(%n: i64) {
      eco.dbg %n : i64
      eco.return
    } continuation {
      eco.jump 0(%c42 : i64)
    }
    // CHECK: 42

    // Test 2: Computed value before jump
    eco.joinpoint 1(%x: i64) {
      eco.dbg %x : i64
      eco.return
    } continuation {
      %val = arith.constant 100 : i64
      eco.jump 1(%val : i64)
    }
    // CHECK: 100

    // Test 3: Negative value
    eco.joinpoint 2(%v: i64) {
      eco.dbg %v : i64
      eco.return
    } continuation {
      %neg = arith.constant -7 : i64
      eco.jump 2(%neg : i64)
    }
    // CHECK: -7

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
