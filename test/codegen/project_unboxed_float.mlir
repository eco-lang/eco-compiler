// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.project extracting unboxed f64 values from constructs.

module {
  func.func @main() -> i64 {
    // Create construct with unboxed f64 fields
    %f1 = arith.constant 3.14159 : f64
    %f2 = arith.constant 2.71828 : f64
    %f3 = arith.constant -1.5 : f64

    // All f64 unboxed (bitmap bits would need to cover f64)
    // Since f64 and i64 are same size, we can use unboxed_bitmap
    %obj1 = eco.construct(%f1, %f2, %f3) {
      tag = 0 : i64,
      size = 3 : i64,
      unboxed_bitmap = 7 : i64
    } : (f64, f64, f64) -> !eco.value
    eco.dbg %obj1 : !eco.value
    // CHECK: Ctor

    // Project unboxed f64 values
    %p0 = eco.project %obj1[0] : !eco.value -> f64
    %p1 = eco.project %obj1[1] : !eco.value -> f64
    %p2 = eco.project %obj1[2] : !eco.value -> f64

    eco.dbg %p0 : f64
    // CHECK: 3.14159
    eco.dbg %p1 : f64
    // CHECK: 2.71828
    eco.dbg %p2 : f64
    // CHECK: -1.5

    // Do arithmetic on projected values
    %sum = eco.float.add %p0, %p1 : f64
    eco.dbg %sum : f64
    // CHECK: 5.85987

    %prod = eco.float.mul %p0, %p2 : f64
    eco.dbg %prod : f64
    // CHECK: -4.71238

    // Mixed f64 and boxed values
    %b100 = eco.box %f1 : f64 -> !eco.value
    %obj2 = eco.construct(%f1, %b100, %f2) {
      tag = 1 : i64,
      size = 3 : i64,
      unboxed_bitmap = 5 : i64
    } : (f64, !eco.value, f64) -> !eco.value
    eco.dbg %obj2 : !eco.value
    // CHECK: Ctor

    %q0 = eco.project %obj2[0] : !eco.value -> f64
    %q1 = eco.project %obj2[1] : !eco.value -> !eco.value
    %q2 = eco.project %obj2[2] : !eco.value -> f64
    eco.dbg %q0 : f64
    // CHECK: 3.14159
    eco.dbg %q1 : !eco.value
    // CHECK: 3.14159
    eco.dbg %q2 : f64
    // CHECK: 2.71828

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
