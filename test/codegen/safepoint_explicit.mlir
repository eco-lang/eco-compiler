// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.safepoint operation explicitly.
// Safepoints are lowered to no-ops but should not crash.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64

    // Safepoint at start (with required stack_map attribute)
    "eco.safepoint"() {stack_map = ""} : () -> ()

    eco.dbg %c1 : i64
    // CHECK: 1

    // Safepoint between operations
    "eco.safepoint"() {stack_map = "c1,c2"} : () -> ()

    %sum = eco.int.add %c1, %c2 : i64
    eco.dbg %sum : i64
    // CHECK: 3

    // Multiple safepoints in sequence
    "eco.safepoint"() {stack_map = "sum"} : () -> ()
    "eco.safepoint"() {stack_map = ""} : () -> ()
    "eco.safepoint"() {stack_map = "c3"} : () -> ()

    %sum2 = eco.int.add %sum, %c3 : i64
    eco.dbg %sum2 : i64
    // CHECK: 6

    // Safepoint at end
    "eco.safepoint"() {stack_map = "sum2"} : () -> ()

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
