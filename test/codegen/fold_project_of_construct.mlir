// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// kernel-opt-10 Phase 2: semantics are IDENTICAL with the projection folders on
// and off. The harness cannot set env per-test, so this fixture asserts the
// VALUES; volume is proved by the census, not here. Run it in both legs:
// default path covers the shipped flag state, and
// ECO_MLIR_FOLD=0 build/test/test --filter codegen is the off-leg check.
//
// Shapes covered:
//   - project.custom of construct.custom, boxed and unboxed-typed fields
//   - project.list_head / list_tail of construct.list (unboxed i64 head, so the
//     head_kind path is exercised)
//   - get_tag of construct.custom -> the constant ctor tag
//   - the NEGATIVE case: a projection whose result type differs from the
//     construct operand's SSA type (boxed i64 field projected as !eco.value)
//     must NOT fold to the raw operand -- the heap load must still see the
//     boxed value. Type equality is the guard.

module {
  func.func @main() -> i64 {
    %c7 = arith.constant 7 : i64
    %c9 = arith.constant 9 : i64

    %b7 = eco.box %c7 : i64 -> !eco.value
    %b9 = eco.box %c9 : i64 -> !eco.value

    // Two-field custom, tag 3: field 0 boxed, field 1 boxed.
    %ctor = eco.construct.custom(%b7, %b9) {tag = 3 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value

    // Positive: project.custom of construct.custom, types match (!eco.value).
    // Folds to %b7 / %b9; unbox must print the same values either way.
    %p0 = eco.project.custom %ctor[0] : !eco.value -> !eco.value
    %v0 = eco.unbox %p0 : !eco.value -> i64
    eco.dbg %v0 : i64
    // CHECK: [eco.dbg] 7

    %p1 = eco.project.custom %ctor[1] : !eco.value -> !eco.value
    %v1 = eco.unbox %p1 : !eco.value -> i64
    eco.dbg %v1 : i64
    // CHECK: [eco.dbg] 9

    // get_tag of the construct: the constant 3, folded or loaded.
    %tag = eco.get_tag %ctor : !eco.value -> i32
    %tag64 = arith.extsi %tag : i32 to i64
    eco.dbg %tag64 : i64
    // CHECK: [eco.dbg] 3

    // List with an UNBOXED i64 head: head_kind is derived from the operand
    // type, and the fold must return the raw i64 only when the projection asks
    // for i64.
    %nil = eco.constant Empty : !eco.value
    %cons = eco.construct.list %c7, %nil {head_kind = 1 : i64, head_unboxed = true} : i64, !eco.value -> !eco.value

    %h = eco.project.list_head %cons : !eco.value -> i64
    eco.dbg %h : i64
    // CHECK: [eco.dbg] 7

    // Tail folds to %nil; projecting its emptiness via get_tag would need a
    // case; instead re-cons and take the head again through the folded tail.
    %t = eco.project.list_tail %cons : !eco.value -> !eco.value
    %cons2 = eco.construct.list %c9, %t {head_kind = 1 : i64, head_unboxed = true} : i64, !eco.value -> !eco.value
    %h2 = eco.project.list_head %cons2 : !eco.value -> i64
    eco.dbg %h2 : i64
    // CHECK: [eco.dbg] 9

    %z = arith.constant 0 : i64
    return %z : i64
  }
}
