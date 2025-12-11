// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project from value after case dispatch.
// Ensures scrutinee is still valid after case matching.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %b30 = eco.box %c30 : i64 -> !eco.value

    // Create a 3-field constructor
    %ctor = eco.construct(%b10, %b20, %b30) {tag = 1 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value

    // Case dispatch on the constructor
    eco.case %ctor [0, 1, 2] {
      // Tag 0 branch - shouldn't execute
      %r = arith.constant 0 : i64
      eco.dbg %r : i64
      eco.return
    }, {
      // Tag 1 branch - should execute
      // Project all fields from the scrutinee
      %f0 = eco.project %ctor[0] : !eco.value -> !eco.value
      %f1 = eco.project %ctor[1] : !eco.value -> !eco.value
      %f2 = eco.project %ctor[2] : !eco.value -> !eco.value

      %v0 = eco.unbox %f0 : !eco.value -> i64
      %v1 = eco.unbox %f1 : !eco.value -> i64
      %v2 = eco.unbox %f2 : !eco.value -> i64

      eco.dbg %v0 : i64
      eco.dbg %v1 : i64
      eco.dbg %v2 : i64

      // Compute sum
      %s01 = eco.int.add %v0, %v1 : i64
      %sum = eco.int.add %s01, %v2 : i64
      eco.dbg %sum : i64
      eco.return
    }, {
      // Tag 2 branch - shouldn't execute
      %r = arith.constant 2 : i64
      eco.dbg %r : i64
      eco.return
    }
    // CHECK: 10
    // CHECK: 20
    // CHECK: 30
    // CHECK: 60

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
