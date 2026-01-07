// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test basic operations that would be used in function calls.
// Note: User-defined func.func can't be translated to LLVM IR in current setup,
// so we inline the logic here to test the same operations.

module {
  func.func @main() -> i64 {
    // Simulate get_42: box constant 42
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    eco.dbg %b42 : !eco.value
    // CHECK: 42

    // Simulate identity: value pass-through
    %i10 = arith.constant 10 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    // Identity is just using the value directly
    eco.dbg %b10 : !eco.value
    // CHECK: 10

    // Simulate make_pair: construct a 2-element structure
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %pair = eco.construct.custom(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %pair : !eco.value
    // CHECK: [1,

    // Simulate box_and_double: double then box
    %i5 = arith.constant 5 : i64
    %two = arith.constant 2 : i64
    %doubled = arith.muli %i5, %two : i64
    %bdoubled = eco.box %doubled : i64 -> !eco.value
    eco.dbg %bdoubled : !eco.value
    // CHECK: 10

    // Chain operations: box(42), use it twice
    %v1 = eco.box %i42 : i64 -> !eco.value
    eco.dbg %v1 : !eco.value
    // CHECK: 42

    // Create a list and project from it
    // Both fields are boxed (!eco.value), so unboxed_bitmap = 0
    %nil = eco.constant Nil : !eco.value
    %list = eco.construct.custom(%v1, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %head = eco.project.custom %list[0] : !eco.value -> !eco.value
    eco.dbg %head : !eco.value
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
