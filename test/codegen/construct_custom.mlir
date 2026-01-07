// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test custom ADT construction simulating Elm's Maybe and Result types.
// Maybe: Nothing (constant) | Just value (ctor=0, 1 field)
// Result: Ok value (ctor=0, 1 field) | Err error (ctor=1, 1 field)

module {
  func.func @main() -> i64 {
    // Maybe.Nothing - uses embedded constant
    %nothing = eco.constant Nothing : !eco.value
    eco.dbg %nothing : !eco.value
    // CHECK: Nothing

    // Maybe.Just 42 - uses ctor=0 with 1 field
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %just42 = eco.construct.custom(%b42) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %just42 : !eco.value
    // CHECK: Ctor0 42

    // Extract value from Just
    %just_val = eco.project.custom %just42[0] : !eco.value -> !eco.value
    eco.dbg %just_val : !eco.value
    // CHECK: 42

    // Result.Ok "success" (simulated with int for now)
    %i100 = arith.constant 100 : i64
    %b100 = eco.box %i100 : i64 -> !eco.value
    %ok_val = eco.construct.custom(%b100) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %ok_val : !eco.value
    // CHECK: Ctor0 100

    // Result.Err "error" - ctor=1
    %i999 = arith.constant 999 : i64
    %b999 = eco.box %i999 : i64 -> !eco.value
    %err_val = eco.construct.custom(%b999) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %err_val : !eco.value
    // CHECK: Ctor1 999

    // Extract from Err
    %err_inner = eco.project.custom %err_val[0] : !eco.value -> !eco.value
    eco.dbg %err_inner : !eco.value
    // CHECK: 999

    // Nested Maybe: Just (Just 7)
    %i7 = arith.constant 7 : i64
    %b7 = eco.box %i7 : i64 -> !eco.value
    %inner_just = eco.construct.custom(%b7) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %outer_just = eco.construct.custom(%inner_just) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %outer_just : !eco.value
    // CHECK: Ctor0 (Ctor0 7)

    // Unwrap twice
    %level1 = eco.project.custom %outer_just[0] : !eco.value -> !eco.value
    %level2 = eco.project.custom %level1[0] : !eco.value -> !eco.value
    eco.dbg %level2 : !eco.value
    // CHECK: 7

    // Simulate a 3-constructor ADT: Red=0, Green=1, Blue=2
    // Each with Unit field to distinguish
    %dummy = eco.constant Unit : !eco.value
    %red = eco.construct.custom(%dummy) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %green = eco.construct.custom(%dummy) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %blue = eco.construct.custom(%dummy) {tag = 2 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %red : !eco.value
    // CHECK: Ctor0
    eco.dbg %green : !eco.value
    // CHECK: Ctor1
    eco.dbg %blue : !eco.value
    // CHECK: Ctor2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
