// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project with larger field indices.

module {
  func.func @main() -> i64 {
    // Create boxed values
    %i0 = arith.constant 100 : i64
    %i1 = arith.constant 101 : i64
    %i2 = arith.constant 102 : i64
    %i3 = arith.constant 103 : i64
    %i4 = arith.constant 104 : i64
    %i5 = arith.constant 105 : i64
    %i6 = arith.constant 106 : i64
    %i7 = arith.constant 107 : i64
    %i8 = arith.constant 108 : i64
    %i9 = arith.constant 109 : i64

    %b0 = eco.box %i0 : i64 -> !eco.value
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b4 = eco.box %i4 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b6 = eco.box %i6 : i64 -> !eco.value
    %b7 = eco.box %i7 : i64 -> !eco.value
    %b8 = eco.box %i8 : i64 -> !eco.value
    %b9 = eco.box %i9 : i64 -> !eco.value

    // Create a 10-field constructor
    %obj = eco.construct(%b0, %b1, %b2, %b3, %b4, %b5, %b6, %b7, %b8, %b9) {tag = 10 : i64, size = 10 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %obj : !eco.value
    // CHECK: Ctor10 100 101 102 103 104 105 106 107 108 109

    // Project field 0 (first)
    %f0 = eco.project %obj[0] : !eco.value -> !eco.value
    eco.dbg %f0 : !eco.value
    // CHECK: 100

    // Project field 5 (middle)
    %f5 = eco.project %obj[5] : !eco.value -> !eco.value
    eco.dbg %f5 : !eco.value
    // CHECK: 105

    // Project field 9 (last)
    %f9 = eco.project %obj[9] : !eco.value -> !eco.value
    eco.dbg %f9 : !eco.value
    // CHECK: 109

    // Project field 7
    %f7 = eco.project %obj[7] : !eco.value -> !eco.value
    eco.dbg %f7 : !eco.value
    // CHECK: 107

    // Create an 8-field constructor with unboxed integers
    %obj2 = eco.construct(%i0, %i1, %i2, %i3, %i4, %i5, %i6, %i7) {tag = 8 : i64, size = 8 : i64, unboxed_bitmap = 255 : i64} : (i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value
    eco.dbg %obj2 : !eco.value
    // CHECK: Ctor8 100 101 102 103 104 105 106 107

    // Project unboxed field 6
    %uf6 = eco.project %obj2[6] : !eco.value -> i64
    eco.dbg %uf6 : i64
    // CHECK: 106

    // Project unboxed field 7
    %uf7 = eco.project %obj2[7] : !eco.value -> i64
    eco.dbg %uf7 : i64
    // CHECK: 107

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
