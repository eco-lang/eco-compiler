// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct for building cons lists of varying lengths.

module {
  func.func @main() -> i64 {
    // Empty list
    %nil = eco.constant Nil : !eco.value
    eco.dbg %nil : !eco.value
    // CHECK: []

    // Single element list: [42]
    // Head is boxed (!eco.value), so unboxed_bitmap = 0
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %list1 = eco.construct.custom(%b42, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list1 : !eco.value
    // CHECK: [42]

    // Two element list: [10, 20]
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    %l2_tail = eco.construct.custom(%b20, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list2 = eco.construct.custom(%b10, %l2_tail) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list2 : !eco.value
    // CHECK: [10, 20]

    // Three element list: [1, 2, 3]
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %l3_3 = eco.construct.custom(%b3, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %l3_2 = eco.construct.custom(%b2, %l3_3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list3 = eco.construct.custom(%b1, %l3_2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list3 : !eco.value
    // CHECK: [1, 2, 3]

    // Five element list: [5, 4, 3, 2, 1]
    %i4 = arith.constant 4 : i64
    %i5 = arith.constant 5 : i64
    %b4 = eco.box %i4 : i64 -> !eco.value
    %b5 = eco.box %i5 : i64 -> !eco.value
    %l5_1 = eco.construct.custom(%b1, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %l5_2 = eco.construct.custom(%b2, %l5_1) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %l5_3 = eco.construct.custom(%b3, %l5_2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %l5_4 = eco.construct.custom(%b4, %l5_3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list5 = eco.construct.custom(%b5, %l5_4) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list5 : !eco.value
    // CHECK: [5, 4, 3, 2, 1]

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
