// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with alternating boxed/unboxed fields.
// Different patterns than existing tests.

module {
  func.func @main() -> i64 {
    // Create values
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    %b30 = eco.box %i30 : i64 -> !eco.value

    // Pattern: boxed, unboxed, boxed (bitmap = 0b010 = 2)
    %obj1 = eco.construct(%b10, %i20, %b30) {
      tag = 0 : i64,
      size = 3 : i64,
      unboxed_bitmap = 2 : i64
    } : (!eco.value, i64, !eco.value) -> !eco.value
    eco.dbg %obj1 : !eco.value
    // CHECK: Ctor

    // Project each field
    %p0 = eco.project %obj1[0] : !eco.value -> !eco.value
    %p1 = eco.project %obj1[1] : !eco.value -> i64
    %p2 = eco.project %obj1[2] : !eco.value -> !eco.value
    eco.dbg %p0 : !eco.value
    // CHECK: 10
    eco.dbg %p1 : i64
    // CHECK: 20
    eco.dbg %p2 : !eco.value
    // CHECK: 30

    // Pattern: unboxed, boxed, unboxed, boxed (bitmap = 0b0101 = 5)
    %i40 = arith.constant 40 : i64
    %b40 = eco.box %i40 : i64 -> !eco.value
    %obj2 = eco.construct(%i10, %b20, %i30, %b40) {
      tag = 1 : i64,
      size = 4 : i64,
      unboxed_bitmap = 5 : i64
    } : (i64, !eco.value, i64, !eco.value) -> !eco.value
    eco.dbg %obj2 : !eco.value
    // CHECK: Ctor

    %q0 = eco.project %obj2[0] : !eco.value -> i64
    %q1 = eco.project %obj2[1] : !eco.value -> !eco.value
    %q2 = eco.project %obj2[2] : !eco.value -> i64
    %q3 = eco.project %obj2[3] : !eco.value -> !eco.value
    eco.dbg %q0 : i64
    // CHECK: 10
    eco.dbg %q1 : !eco.value
    // CHECK: 20
    eco.dbg %q2 : i64
    // CHECK: 30
    eco.dbg %q3 : !eco.value
    // CHECK: 40

    // Pattern: first unboxed, rest boxed (bitmap = 0b0001 = 1)
    %obj3 = eco.construct(%i10, %b20, %b30, %b40) {
      tag = 2 : i64,
      size = 4 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %obj3 : !eco.value
    // CHECK: Ctor

    %r0 = eco.project %obj3[0] : !eco.value -> i64
    %r1 = eco.project %obj3[1] : !eco.value -> !eco.value
    eco.dbg %r0 : i64
    // CHECK: 10
    eco.dbg %r1 : !eco.value
    // CHECK: 20

    // Pattern: last unboxed, rest boxed (bitmap = 0b1000 = 8)
    %obj4 = eco.construct(%b10, %b20, %b30, %i40) {
      tag = 3 : i64,
      size = 4 : i64,
      unboxed_bitmap = 8 : i64
    } : (!eco.value, !eco.value, !eco.value, i64) -> !eco.value
    eco.dbg %obj4 : !eco.value
    // CHECK: Ctor

    %s0 = eco.project %obj4[0] : !eco.value -> !eco.value
    %s3 = eco.project %obj4[3] : !eco.value -> i64
    eco.dbg %s0 : !eco.value
    // CHECK: 10
    eco.dbg %s3 : i64
    // CHECK: 40

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
