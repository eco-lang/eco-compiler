// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with many unboxed fields.
// Tests the unboxed bitmap with larger values.

module {
  func.func @main() -> i64 {
    // Create 8 unboxed i64 values
    %v0 = arith.constant 10 : i64
    %v1 = arith.constant 20 : i64
    %v2 = arith.constant 30 : i64
    %v3 = arith.constant 40 : i64
    %v4 = arith.constant 50 : i64
    %v5 = arith.constant 60 : i64
    %v6 = arith.constant 70 : i64
    %v7 = arith.constant 80 : i64

    // All 8 fields unboxed: bitmap = 0xFF = 255
    %ctor8 = eco.construct.custom(%v0, %v1, %v2, %v3, %v4, %v5, %v6, %v7) {tag = 0 : i64, size = 8 : i64, unboxed_bitmap = 255 : i64} : (i64, i64, i64, i64, i64, i64, i64, i64) -> !eco.value

    eco.dbg %ctor8 : !eco.value
    // CHECK: Ctor0

    // Verify first and last fields
    %p0 = eco.project.custom %ctor8[0] : !eco.value -> i64
    eco.dbg %p0 : i64
    // CHECK: 10

    %p7 = eco.project.custom %ctor8[7] : !eco.value -> i64
    eco.dbg %p7 : i64
    // CHECK: 80

    // Sum all fields to verify integrity
    %s01 = eco.int.add %p0, %v1 : i64
    %s012 = eco.int.add %s01, %v2 : i64
    %s0123 = eco.int.add %s012, %v3 : i64
    %s01234 = eco.int.add %s0123, %v4 : i64
    %s012345 = eco.int.add %s01234, %v5 : i64
    %s0123456 = eco.int.add %s012345, %v6 : i64
    %sum = eco.int.add %s0123456, %p7 : i64
    eco.dbg %sum : i64
    // 10+20+30+40+50+60+70+80 = 360
    // CHECK: 360

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
