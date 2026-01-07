// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with different boxed/unboxed orderings.
// Tests alternating patterns: boxed-unboxed-boxed-unboxed.

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value

    // Create boxed integers
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64
    %i40 = arith.constant 40 : i64

    %b10 = eco.box %i10 : i64 -> !eco.value
    %b30 = eco.box %i30 : i64 -> !eco.value

    // Pattern: [boxed, unboxed, boxed, unboxed]
    // unboxed_bitmap = 10 (0b1010) - bits 1 and 3 are unboxed
    %mixed1 = eco.construct.custom(%b10, %i20, %b30, %i40) {tag = 1 : i64, size = 4 : i64, unboxed_bitmap = 10 : i64} : (!eco.value, i64, !eco.value, i64) -> !eco.value
    eco.dbg %mixed1 : !eco.value
    // CHECK: Ctor1 10 20 30 40

    // Project boxed field (index 0)
    %p0 = eco.project.custom %mixed1[0] : !eco.value -> !eco.value
    eco.dbg %p0 : !eco.value
    // CHECK: 10

    // Project unboxed field (index 1)
    %p1 = eco.project.custom %mixed1[1] : !eco.value -> i64
    eco.dbg %p1 : i64
    // CHECK: 20

    // Project boxed field (index 2)
    %p2 = eco.project.custom %mixed1[2] : !eco.value -> !eco.value
    eco.dbg %p2 : !eco.value
    // CHECK: 30

    // Project unboxed field (index 3)
    %p3 = eco.project.custom %mixed1[3] : !eco.value -> i64
    eco.dbg %p3 : i64
    // CHECK: 40

    // Pattern: [unboxed, boxed, unboxed, boxed]
    // unboxed_bitmap = 5 (0b0101) - bits 0 and 2 are unboxed
    %b20 = eco.box %i20 : i64 -> !eco.value
    %b40 = eco.box %i40 : i64 -> !eco.value

    %mixed2 = eco.construct.custom(%i10, %b20, %i30, %b40) {tag = 2 : i64, size = 4 : i64, unboxed_bitmap = 5 : i64} : (i64, !eco.value, i64, !eco.value) -> !eco.value
    eco.dbg %mixed2 : !eco.value
    // CHECK: Ctor2 10 20 30 40

    // Project each field
    %q0 = eco.project.custom %mixed2[0] : !eco.value -> i64
    eco.dbg %q0 : i64
    // CHECK: 10

    %q1 = eco.project.custom %mixed2[1] : !eco.value -> !eco.value
    eco.dbg %q1 : !eco.value
    // CHECK: 20

    %q2 = eco.project.custom %mixed2[2] : !eco.value -> i64
    eco.dbg %q2 : i64
    // CHECK: 30

    %q3 = eco.project.custom %mixed2[3] : !eco.value -> !eco.value
    eco.dbg %q3 : !eco.value
    // CHECK: 40

    // Pattern: [boxed, boxed, unboxed, unboxed]
    // unboxed_bitmap = 12 (0b1100) - bits 2 and 3 are unboxed
    %mixed3 = eco.construct.custom(%b10, %b20, %i30, %i40) {tag = 3 : i64, size = 4 : i64, unboxed_bitmap = 12 : i64} : (!eco.value, !eco.value, i64, i64) -> !eco.value
    eco.dbg %mixed3 : !eco.value
    // CHECK: Ctor3 10 20 30 40

    // Project unboxed fields
    %r2 = eco.project.custom %mixed3[2] : !eco.value -> i64
    eco.dbg %r2 : i64
    // CHECK: 30

    %r3 = eco.project.custom %mixed3[3] : !eco.value -> i64
    eco.dbg %r3 : i64
    // CHECK: 40

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
