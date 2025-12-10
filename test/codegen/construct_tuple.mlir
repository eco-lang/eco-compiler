// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct for building tuple-like structures and eco.project for field access.
// Note: 2-element tag-0 structs display as list-like, 3+ elements as CtorN format

module {
  func.func @main() -> i64 {
    // 2-tuple: (10, 20) - displays as list-like due to Cons-like structure
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b20 = eco.box %i20 : i64 -> !eco.value
    %tuple2 = eco.construct(%b10, %b20) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %tuple2 : !eco.value
    // CHECK: [10,

    // Project first field
    %fst = eco.project %tuple2[0] : !eco.value -> !eco.value
    eco.dbg %fst : !eco.value
    // CHECK: 10

    // Project second field
    %snd = eco.project %tuple2[1] : !eco.value -> !eco.value
    eco.dbg %snd : !eco.value
    // CHECK: 20

    // 3-tuple: (1, 2, 3)
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value
    %tuple3 = eco.construct(%b1, %b2, %b3) {tag = 0 : i64, size = 3 : i64} : (!eco.value, !eco.value, !eco.value) -> !eco.value
    eco.dbg %tuple3 : !eco.value
    // CHECK: Ctor0 1 2 3

    // Project middle field from 3-tuple
    %mid = eco.project %tuple3[1] : !eco.value -> !eco.value
    eco.dbg %mid : !eco.value
    // CHECK: 2

    // Project last field from 3-tuple
    %last = eco.project %tuple3[2] : !eco.value -> !eco.value
    eco.dbg %last : !eco.value
    // CHECK: 3

    // Mixed types: (42, 3.14) - 2-element tag-0
    %i42 = arith.constant 42 : i64
    %fpi = arith.constant 3.14 : f64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %bpi = eco.box %fpi : f64 -> !eco.value
    %mixed = eco.construct(%b42, %bpi) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: [42,

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
