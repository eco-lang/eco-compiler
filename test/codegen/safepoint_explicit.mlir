// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.safepoint operation explicitly.
// Safepoints carry live eco.value roots as operands and are lowered to no-ops
// (will become gc.statepoint + gc.relocate in the future).

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64

    // Safepoint with no live roots
    eco.safepoint

    eco.dbg %c1 : i64
    // CHECK: 1

    // Safepoint with eco.value live roots
    %nil = eco.constant Nil : !eco.value
    %true = eco.constant True : !eco.value
    eco.safepoint %nil, %true : !eco.value, !eco.value

    %sum = eco.int.add %c1, %c2 : i64
    eco.dbg %sum : i64
    // CHECK: 3

    // Multiple safepoints in sequence
    eco.safepoint %nil : !eco.value
    eco.safepoint
    eco.safepoint %true : !eco.value

    %sum2 = eco.int.add %sum, %c3 : i64
    eco.dbg %sum2 : i64
    // CHECK: 6

    // Safepoint at end
    eco.safepoint %nil, %true : !eco.value, !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
