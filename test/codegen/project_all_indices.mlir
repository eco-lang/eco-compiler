// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test projecting every field from a constructor.
// Tests index handling across multiple fields.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64
    %c40 = arith.constant 40 : i64
    %c50 = arith.constant 50 : i64

    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %b30 = eco.box %c30 : i64 -> !eco.value
    %b40 = eco.box %c40 : i64 -> !eco.value
    %b50 = eco.box %c50 : i64 -> !eco.value

    %ctor = eco.construct(%b10, %b20, %b30, %b40, %b50) {tag = 0 : i64, size = 5 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    // Project index 0
    %p0 = eco.project %ctor[0] : !eco.value -> !eco.value
    %v0 = eco.unbox %p0 : !eco.value -> i64
    eco.dbg %v0 : i64
    // CHECK: [eco.dbg] 10

    // Project index 1
    %p1 = eco.project %ctor[1] : !eco.value -> !eco.value
    %v1 = eco.unbox %p1 : !eco.value -> i64
    eco.dbg %v1 : i64
    // CHECK: [eco.dbg] 20

    // Project index 2
    %p2 = eco.project %ctor[2] : !eco.value -> !eco.value
    %v2 = eco.unbox %p2 : !eco.value -> i64
    eco.dbg %v2 : i64
    // CHECK: [eco.dbg] 30

    // Project index 3
    %p3 = eco.project %ctor[3] : !eco.value -> !eco.value
    %v3 = eco.unbox %p3 : !eco.value -> i64
    eco.dbg %v3 : i64
    // CHECK: [eco.dbg] 40

    // Project index 4
    %p4 = eco.project %ctor[4] : !eco.value -> !eco.value
    %v4 = eco.unbox %p4 : !eco.value -> i64
    eco.dbg %v4 : i64
    // CHECK: [eco.dbg] 50

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
