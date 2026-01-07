// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test nested data structures: lists of tuples, tuples of lists.

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value

    // Build a list of "pairs": [(1, 2), (3, 4)]
    // First, create pair (1, 2)
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %pair1 = eco.construct.custom(%b1, %b2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Create pair (3, 4)
    %i3 = arith.constant 3 : i64
    %i4 = arith.constant 4 : i64
    %b3 = eco.box %i3 : i64 -> !eco.value
    %b4 = eco.box %i4 : i64 -> !eco.value
    %pair2 = eco.construct.custom(%b3, %b4) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Build list of pairs
    %tail1 = eco.construct.custom(%pair2, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list_of_pairs = eco.construct.custom(%pair1, %tail1) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %list_of_pairs : !eco.value
    // CHECK: Ctor0 (Ctor0 1 2) (Ctor0 (Ctor0 3 4) [])

    // Project first pair and then its first element
    %first_pair = eco.project.custom %list_of_pairs[0] : !eco.value -> !eco.value
    eco.dbg %first_pair : !eco.value
    // CHECK: Ctor0 1 2

    %first_elem = eco.project.custom %first_pair[0] : !eco.value -> !eco.value
    eco.dbg %first_elem : !eco.value
    // CHECK: 1

    // Build a "tuple of lists": ([10, 20], [30])
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %i30 = arith.constant 30 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    %b30 = eco.box %i30 : i64 -> !eco.value

    // List [10, 20] - boxed values, so unboxed_bitmap = 0
    %l1_tail = eco.construct.custom(%b20, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %list_a = eco.construct.custom(%b10, %l1_tail) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value

    // List [30] - boxed value, so unboxed_bitmap = 0
    %list_b = eco.construct.custom(%b30, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Tuple of lists
    %tuple_of_lists = eco.construct.custom(%list_a, %list_b) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %tuple_of_lists : !eco.value
    // CHECK: Ctor0 (Ctor0 10 (Ctor0 20 [])) (Ctor0 30 [])

    // Project second list and its head
    %second_list = eco.project.custom %tuple_of_lists[1] : !eco.value -> !eco.value
    eco.dbg %second_list : !eco.value
    // CHECK: Ctor0 30 []

    %head_of_second = eco.project.custom %second_list[0] : !eco.value -> !eco.value
    eco.dbg %head_of_second : !eco.value
    // CHECK: 30

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
