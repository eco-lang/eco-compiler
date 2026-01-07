// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test storing nested constructed values in globals.
// Tests that deeply nested heap objects survive global storage.

module {
  eco.global @nested_global

  func.func @main() -> i64 {
    // Build a nested structure: [[1, 2], [3, 4]]
    %nil = eco.constant Nil : !eco.value

    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64

    %b1 = eco.box %c1 : i64 -> !eco.value
    %b2 = eco.box %c2 : i64 -> !eco.value
    %b3 = eco.box %c3 : i64 -> !eco.value
    %b4 = eco.box %c4 : i64 -> !eco.value

    // Build [2]
    %list2 = eco.construct.custom(%b2, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    // Build [1, 2]
    %inner1 = eco.construct.custom(%b1, %list2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Build [4]
    %list4 = eco.construct.custom(%b4, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    // Build [3, 4]
    %inner2 = eco.construct.custom(%b3, %list4) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Build [[3, 4]]
    %outer2 = eco.construct.custom(%inner2, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    // Build [[1, 2], [3, 4]]
    %outer = eco.construct.custom(%inner1, %outer2) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Store in global
    eco.store_global %outer, @nested_global

    // Load and verify structure
    %loaded = eco.load_global @nested_global
    eco.dbg %loaded : !eco.value
    // CHECK: Ctor0 (Ctor0 1 (Ctor0 2 [])) (Ctor0 (Ctor0 3 (Ctor0 4 [])) [])

    // Project into the structure to verify it's intact
    %first_list = eco.project.custom %loaded[0] : !eco.value -> !eco.value
    eco.dbg %first_list : !eco.value
    // CHECK: Ctor0 1 (Ctor0 2 [])

    %second_elem = eco.project.custom %loaded[1] : !eco.value -> !eco.value
    %second_list = eco.project.custom %second_elem[0] : !eco.value -> !eco.value
    eco.dbg %second_list : !eco.value
    // CHECK: Ctor0 3 (Ctor0 4 [])

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
