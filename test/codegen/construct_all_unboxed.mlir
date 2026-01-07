// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with all fields unboxed (bitmap = all 1s).
// This tests the maximum unboxed bitmap case.

module {
  func.func @main() -> i64 {
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %i4 = arith.constant 4 : i64

    // Construct with 4 unboxed i64 fields
    // unboxed_bitmap = 0b1111 = 15
    %ctor4 = eco.construct.custom(%i1, %i2, %i3, %i4) {tag = 0 : i64, size = 4 : i64, unboxed_bitmap = 15 : i64} : (i64, i64, i64, i64) -> !eco.value

    eco.dbg %ctor4 : !eco.value
    // CHECK: Ctor0

    // Project each field back
    %p0 = eco.project.custom %ctor4[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    // CHECK: 1

    %p1 = eco.project.custom %ctor4[1] : !eco.value -> i64
    eco.dbg %p1 : i64
    // CHECK: 2

    %p2 = eco.project.custom %ctor4[2] : !eco.value -> i64
    eco.dbg %p2 : i64
    // CHECK: 3

    %p3 = eco.project.custom %ctor4[3] : !eco.value -> i64
    eco.dbg %p3 : i64
    // CHECK: 4

    // Test with mixed types: i64 and f64 all unboxed
    %f1 = arith.constant 1.5 : f64
    %f2 = arith.constant 2.5 : f64

    // 2 i64 + 2 f64, all unboxed: bitmap = 0b1111 = 15
    %mixed = eco.construct.custom(%i1, %f1, %i2, %f2) {tag = 1 : i64, size = 4 : i64, unboxed_bitmap = 15 : i64} : (i64, f64, i64, f64) -> !eco.value

    %pm0 = eco.project.custom %mixed[0] : !eco.value -> i64
    eco.dbg %pm0 : i64
    // CHECK: 1

    %pm1 = eco.project.custom %mixed[1] : !eco.value -> f64
    eco.dbg %pm1 : f64
    // CHECK: 1.5

    %pm2 = eco.project.custom %mixed[2] : !eco.value -> i64
    eco.dbg %pm2 : i64
    // CHECK: 2

    %pm3 = eco.project.custom %mixed[3] : !eco.value -> f64
    eco.dbg %pm3 : f64
    // CHECK: 2.5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
