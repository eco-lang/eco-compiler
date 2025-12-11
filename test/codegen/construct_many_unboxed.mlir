// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with many unboxed fields (4-5 unboxed integers).
// Tests unboxed_bitmap with multiple bits set.

module {
  func.func @main() -> i64 {
    // 4 unboxed integers: unboxed_bitmap = 15 (0b1111)
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %i4 = arith.constant 4 : i64

    %quad = eco.construct(%i1, %i2, %i3, %i4) {tag = 10 : i64, size = 4 : i64, unboxed_bitmap = 15 : i64} : (i64, i64, i64, i64) -> !eco.value
    eco.dbg %quad : !eco.value
    // CHECK: Ctor10 1 2 3 4

    // Project each field
    %p0 = eco.project %quad[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    // CHECK: 1

    %p1 = eco.project %quad[1] : !eco.value -> i64
    eco.dbg %p1 : i64
    // CHECK: 2

    %p2 = eco.project %quad[2] : !eco.value -> i64
    eco.dbg %p2 : i64
    // CHECK: 3

    %p3 = eco.project %quad[3] : !eco.value -> i64
    eco.dbg %p3 : i64
    // CHECK: 4

    // 5 unboxed integers: unboxed_bitmap = 31 (0b11111)
    %i5 = arith.constant 5 : i64
    %quint = eco.construct(%i1, %i2, %i3, %i4, %i5) {tag = 11 : i64, size = 5 : i64, unboxed_bitmap = 31 : i64} : (i64, i64, i64, i64, i64) -> !eco.value
    eco.dbg %quint : !eco.value
    // CHECK: Ctor11 1 2 3 4 5

    // Project last field
    %p4 = eco.project %quint[4] : !eco.value -> i64
    eco.dbg %p4 : i64
    // CHECK: 5

    // 4 unboxed floats: unboxed_bitmap = 15 (0b1111)
    %f1 = arith.constant 1.1 : f64
    %f2 = arith.constant 2.2 : f64
    %f3 = arith.constant 3.3 : f64
    %f4 = arith.constant 4.4 : f64

    %quad_float = eco.construct(%f1, %f2, %f3, %f4) {tag = 20 : i64, size = 4 : i64, unboxed_bitmap = 15 : i64} : (f64, f64, f64, f64) -> !eco.value
    // Note: Unboxed floats print as raw bits in custom print
    eco.dbg %quad_float : !eco.value
    // CHECK: Ctor20

    // Project and verify floats
    %pf0 = eco.project %quad_float[0] : !eco.value -> f64
    eco.dbg %pf0 : f64
    // CHECK: 1.1

    %pf3 = eco.project %quad_float[3] : !eco.value -> f64
    eco.dbg %pf3 : f64
    // CHECK: 4.4

    // Unboxed with negative values
    %neg1 = arith.constant -100 : i64
    %neg2 = arith.constant -200 : i64
    %neg3 = arith.constant -300 : i64
    %neg4 = arith.constant -400 : i64

    %quad_neg = eco.construct(%neg1, %neg2, %neg3, %neg4) {tag = 30 : i64, size = 4 : i64, unboxed_bitmap = 15 : i64} : (i64, i64, i64, i64) -> !eco.value
    eco.dbg %quad_neg : !eco.value
    // CHECK: Ctor30 -100 -200 -300 -400

    %pn2 = eco.project %quad_neg[2] : !eco.value -> i64
    eco.dbg %pn2 : i64
    // CHECK: -300

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
