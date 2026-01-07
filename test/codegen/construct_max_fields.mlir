// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test constructor with many fields (approaching bitmap limit).
// The unboxed_bitmap is 64 bits, so max 64 fields with unboxed tracking.

module {
  func.func @main() -> i64 {
    // Create boxed values
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64
    %c5 = arith.constant 5 : i64
    %c6 = arith.constant 6 : i64
    %c7 = arith.constant 7 : i64
    %c8 = arith.constant 8 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value
    %b5 = eco.box %c5 : i64 -> !eco.value
    %b6 = eco.box %c6 : i64 -> !eco.value
    %b7 = eco.box %c7 : i64 -> !eco.value
    %b8 = eco.box %c8 : i64 -> !eco.value

    // Constructor with 8 fields
    %ctor8 = eco.construct.custom(%b1, %b2, %b3, %b4, %b5, %b6, %b7, %b8) {tag = 0 : i64, size = 8 : i64} : (!eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value, !eco.value) -> !eco.value

    // Project each field and sum
    %p1 = eco.project.custom %ctor8[0] : !eco.value -> !eco.value
    %p2 = eco.project.custom %ctor8[1] : !eco.value -> !eco.value
    %p3 = eco.project.custom %ctor8[2] : !eco.value -> !eco.value
    %p4 = eco.project.custom %ctor8[3] : !eco.value -> !eco.value
    %p5 = eco.project.custom %ctor8[4] : !eco.value -> !eco.value
    %p6 = eco.project.custom %ctor8[5] : !eco.value -> !eco.value
    %p7 = eco.project.custom %ctor8[6] : !eco.value -> !eco.value
    %p8 = eco.project.custom %ctor8[7] : !eco.value -> !eco.value

    %v1 = eco.unbox %p1 : !eco.value -> i64
    %v2 = eco.unbox %p2 : !eco.value -> i64
    %v3 = eco.unbox %p3 : !eco.value -> i64
    %v4 = eco.unbox %p4 : !eco.value -> i64
    %v5 = eco.unbox %p5 : !eco.value -> i64
    %v6 = eco.unbox %p6 : !eco.value -> i64
    %v7 = eco.unbox %p7 : !eco.value -> i64
    %v8 = eco.unbox %p8 : !eco.value -> i64

    %s1 = eco.int.add %v1, %v2 : i64
    %s2 = eco.int.add %s1, %v3 : i64
    %s3 = eco.int.add %s2, %v4 : i64
    %s4 = eco.int.add %s3, %v5 : i64
    %s5 = eco.int.add %s4, %v6 : i64
    %s6 = eco.int.add %s5, %v7 : i64
    %sum = eco.int.add %s6, %v8 : i64

    eco.dbg %sum : i64
    // CHECK: [eco.dbg] 36

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
