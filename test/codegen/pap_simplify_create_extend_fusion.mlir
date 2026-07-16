// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// H6.2.5 M1 (P6) behavioral pin: a NON-saturating typed papExtend over a
// single-use papCreate fuses into ONE papCreate carrying the args as
// leading values (object-equivalent: the runtime splices values[] with
// call args uniformly at saturation). Composition: the later SATURATING
// typed extend then sees a papCreate base directly and P1 converts the
// whole thing to a direct call — the create/extend split used to hide
// this from P1.
//
// @partial_then_saturate: P6 (fuse 1 arg) then P1 (direct call @add3).
// @partial_escapes_generic: the fused partial (num_captured=1) is
// saturated through the GENERIC runtime apply path — pins the heap-object
// equivalence (n_values=1 create behaves exactly like create+extend).
// @multi_use_negative: the create has TWO extend uses — P6 must NOT fire
// (hasOneUse fence); both partials still evaluate correctly.

module {
  func.func @add3(%a: i64, %b: i64, %c: i64) -> i64 {
    %ab = eco.int.add %a, %b : i64
    %abc = eco.int.add %ab, %c : i64
    eco.return %abc : i64
  }

  func.func @main() -> i64 {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64

    // --- P6 then P1: create + non-saturating extend + saturating extend.
    %pap = "eco.papCreate"() {
      function = @add3,
      arity = 3 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %p1 = "eco.papExtend"(%pap, %c1) {
      remaining_arity = 3 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64) -> !eco.value

    %r1 = "eco.papExtend"(%p1, %c2, %c3) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 5 : i64,
      _result_kind = 1 : i8,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64, i64) -> i64

    eco.dbg %r1 : i64
    // CHECK: [eco.dbg] 6

    // --- Fused partial saturated through the GENERIC apply path.
    %pap2 = "eco.papCreate"() {
      function = @add3,
      arity = 3 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %p2 = "eco.papExtend"(%pap2, %c10) {
      remaining_arity = 3 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64) -> !eco.value

    %r2 = "eco.papExtend"(%p2, %c2, %c3) {
      newargs_unboxed_bitmap = 5 : i64,
      _result_kind = 1 : i8,
      _call_kind = "segmentation_unknown"
    } : (!eco.value, i64, i64) -> i64

    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] 15

    // --- Negative: multi-use create — P6 must not fire; both correct.
    %pap3 = "eco.papCreate"() {
      function = @add3,
      arity = 3 : i64,
      num_captured = 0 : i64,
      unboxed_bitmap = 0 : i64
    } : () -> !eco.value

    %p3a = "eco.papExtend"(%pap3, %c10) {
      remaining_arity = 3 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64) -> !eco.value

    %p3b = "eco.papExtend"(%pap3, %c20) {
      remaining_arity = 3 : i64,
      newargs_unboxed_bitmap = 1 : i64,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64) -> !eco.value

    %r3a = "eco.papExtend"(%p3a, %c2, %c3) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 5 : i64,
      _result_kind = 1 : i8,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64, i64) -> i64

    %r3b = "eco.papExtend"(%p3b, %c2, %c3) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 5 : i64,
      _result_kind = 1 : i8,
      _call_kind = "direct_known_segmentation"
    } : (!eco.value, i64, i64) -> i64

    eco.dbg %r3a : i64
    // CHECK: [eco.dbg] 15
    eco.dbg %r3b : i64
    // CHECK: [eco.dbg] 25

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
