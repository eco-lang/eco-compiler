// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Integration test: simulate List.map (+1) over a list.
// All operations inlined since user-defined functions can't be translated to LLVM.

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value

    // Build input list [1, 2, 3]
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %l3 = eco.construct.custom(%b3, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %l2 = eco.construct.custom(%b2, %l3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %input = eco.construct.custom(%b1, %l2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %input : !eco.value
    // CHECK: Ctor0 1 (Ctor0 2 (Ctor0 3 []))

    // Manual map (+1) over the list (inlined)
    // Extract elements
    %h1 = eco.project.custom %input[0] : !eco.value -> !eco.value
    %t1 = eco.project.custom %input[1] : !eco.value -> !eco.value
    %h2 = eco.project.custom %t1[0] : !eco.value -> !eco.value
    %t2 = eco.project.custom %t1[1] : !eco.value -> !eco.value
    %h3 = eco.project.custom %t2[0] : !eco.value -> !eco.value

    // Apply add_one to each element (inlined: unbox, add 1, rebox)
    %one = arith.constant 1 : i64
    %v1 = eco.unbox %h1 : !eco.value -> i64
    %v1_plus = arith.addi %v1, %one : i64
    %m1 = eco.box %v1_plus : i64 -> !eco.value

    %v2 = eco.unbox %h2 : !eco.value -> i64
    %v2_plus = arith.addi %v2, %one : i64
    %m2 = eco.box %v2_plus : i64 -> !eco.value

    %v3 = eco.unbox %h3 : !eco.value -> i64
    %v3_plus = arith.addi %v3, %one : i64
    %m3 = eco.box %v3_plus : i64 -> !eco.value

    // Rebuild result list [2, 3, 4]
    %r3 = eco.construct.custom(%m3, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %r2 = eco.construct.custom(%m2, %r3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %result = eco.construct.custom(%m1, %r2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %result : !eco.value
    // CHECK: Ctor0 2 (Ctor0 3 (Ctor0 4 []))

    // Apply double to each element of [1, 2, 3] (inlined: unbox, mul 2, rebox)
    %two = arith.constant 2 : i64
    %d1_val = arith.muli %v1, %two : i64
    %d1 = eco.box %d1_val : i64 -> !eco.value

    %d2_val = arith.muli %v2, %two : i64
    %d2 = eco.box %d2_val : i64 -> !eco.value

    %d3_val = arith.muli %v3, %two : i64
    %d3 = eco.box %d3_val : i64 -> !eco.value

    %dr3 = eco.construct.custom(%d3, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %dr2 = eco.construct.custom(%d2, %dr3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %doubled_list = eco.construct.custom(%d1, %dr2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %doubled_list : !eco.value
    // CHECK: Ctor0 2 (Ctor0 4 (Ctor0 6 []))

    // Compose: double(add_one(x)) for each element
    // [1,2,3] -> add_one -> [2,3,4] -> double -> [4,6,8]
    %c1_val = arith.muli %v1_plus, %two : i64
    %c1d = eco.box %c1_val : i64 -> !eco.value

    %c2_val = arith.muli %v2_plus, %two : i64
    %c2d = eco.box %c2_val : i64 -> !eco.value

    %c3_val = arith.muli %v3_plus, %two : i64
    %c3d = eco.box %c3_val : i64 -> !eco.value

    %cr3 = eco.construct.custom(%c3d, %nil) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %cr2 = eco.construct.custom(%c2d, %cr3) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value
    %composed = eco.construct.custom(%c1d, %cr2) {tag = 0 : i64, size = 2 : i64, unboxed_bitmap = 0 : i64} : (!eco.value, !eco.value) -> !eco.value

    eco.dbg %composed : !eco.value
    // CHECK: Ctor0 4 (Ctor0 6 (Ctor0 8 []))

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
