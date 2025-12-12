// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project accessing fields.
// Note: Out-of-bounds access is undefined behavior - there's no bounds checking.
// This test verifies normal in-bounds access works correctly.

module {
  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value
    %b5 = eco.box %c5 : i64 -> !eco.value

    // Create 5-element structure
    %ctor5 = eco.construct(%b1, %b2, %b3, %b4, %b5) {tag = 0 : i64, size = 5 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    // Project field 0 (first)
    %f0 = eco.project %ctor5[0] : !eco.value -> !eco.value
    eco.dbg %f0 : !eco.value
    // CHECK: [eco.dbg] 1

    // Project field 1
    %f1 = eco.project %ctor5[1] : !eco.value -> !eco.value
    eco.dbg %f1 : !eco.value
    // CHECK: [eco.dbg] 2

    // Project field 2 (middle)
    %f2 = eco.project %ctor5[2] : !eco.value -> !eco.value
    eco.dbg %f2 : !eco.value
    // CHECK: [eco.dbg] 3

    // Project field 3
    %f3 = eco.project %ctor5[3] : !eco.value -> !eco.value
    eco.dbg %f3 : !eco.value
    // CHECK: [eco.dbg] 4

    // Project field 4 (last)
    %f4 = eco.project %ctor5[4] : !eco.value -> !eco.value
    eco.dbg %f4 : !eco.value
    // CHECK: [eco.dbg] 5

    // Test with single-element construct
    %ctor1 = eco.construct(%b1) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %only = eco.project %ctor1[0] : !eco.value -> !eco.value
    eco.dbg %only : !eco.value
    // CHECK: [eco.dbg] 1

    // Test with 2-element (cons-like)
    %ctor2 = eco.construct(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %head = eco.project %ctor2[0] : !eco.value -> !eco.value
    %tail = eco.project %ctor2[1] : !eco.value -> !eco.value
    eco.dbg %head : !eco.value
    // CHECK: [eco.dbg] 1
    eco.dbg %tail : !eco.value
    // CHECK: [eco.dbg] 2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
