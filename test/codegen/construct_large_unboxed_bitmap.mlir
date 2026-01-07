// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with large unboxed_bitmap values.
// Multiple unboxed fields in the same object.

module {
  func.func @main() -> i64 {
    // Construct with 4 unboxed i64 fields (bitmap = 0b1111 = 15)
    %i1 = arith.constant 100 : i64
    %i2 = arith.constant 200 : i64
    %i3 = arith.constant 300 : i64
    %i4 = arith.constant 400 : i64

    %obj1 = eco.construct.custom(%i1, %i2, %i3, %i4) {
      tag = 0 : i64,
      size = 4 : i64,
      unboxed_bitmap = 15 : i64
    } : (i64, i64, i64, i64) -> !eco.value
    eco.dbg %obj1 : !eco.value
    // CHECK: Ctor

    // Project unboxed fields
    %p0 = eco.project.custom %obj1[0] : !eco.value -> i64
    %p1 = eco.project.custom %obj1[1] : !eco.value -> i64
    %p2 = eco.project.custom %obj1[2] : !eco.value -> i64
    %p3 = eco.project.custom %obj1[3] : !eco.value -> i64
    eco.dbg %p0 : i64
    // CHECK: 100
    eco.dbg %p1 : i64
    // CHECK: 200
    eco.dbg %p2 : i64
    // CHECK: 300
    eco.dbg %p3 : i64
    // CHECK: 400

    // Construct with alternating pattern (bitmap = 0b0101 = 5)
    // Fields 0 and 2 are unboxed, fields 1 and 3 are boxed
    %b10 = eco.box %i1 : i64 -> !eco.value
    %b30 = eco.box %i3 : i64 -> !eco.value
    %obj2 = eco.construct.custom(%i1, %b10, %i3, %b30) {
      tag = 1 : i64,
      size = 4 : i64,
      unboxed_bitmap = 5 : i64
    } : (i64, !eco.value, i64, !eco.value) -> !eco.value
    eco.dbg %obj2 : !eco.value
    // CHECK: Ctor

    // Project from alternating object
    %q0 = eco.project.custom %obj2[0] : !eco.value -> i64
    %q1 = eco.project.custom %obj2[1] : !eco.value -> !eco.value
    %q2 = eco.project.custom %obj2[2] : !eco.value -> i64
    %q3 = eco.project.custom %obj2[3] : !eco.value -> !eco.value
    eco.dbg %q0 : i64
    // CHECK: 100
    eco.dbg %q1 : !eco.value
    // CHECK: 100
    eco.dbg %q2 : i64
    // CHECK: 300
    eco.dbg %q3 : !eco.value
    // CHECK: 300

    // Construct with bitmap = 0b1010 = 10 (fields 1, 3 unboxed)
    %obj3 = eco.construct.custom(%b10, %i2, %b30, %i4) {
      tag = 2 : i64,
      size = 4 : i64,
      unboxed_bitmap = 10 : i64
    } : (!eco.value, i64, !eco.value, i64) -> !eco.value
    eco.dbg %obj3 : !eco.value
    // CHECK: Ctor

    %r1 = eco.project.custom %obj3[1] : !eco.value -> i64
    %r3 = eco.project.custom %obj3[3] : !eco.value -> i64
    eco.dbg %r1 : i64
    // CHECK: 200
    eco.dbg %r3 : i64
    // CHECK: 400

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
