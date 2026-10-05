// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 2 (plans/wide-object-tail-kind-words-phase-2.md 2.1, §S.5): `slot_kinds` on the
// closure ops — one i8 kind per captured operand / newarg (0 boxed, 1 Int, 2 Float,
// 3 Char), equal to the operand's MLIR type kind. The attribute round-trips through the
// parser and printer, alongside or without the legacy u64 bitmap; papCreateGroup carries
// one dense array per sibling (length num_captured; the sibling slots are boxed) and no
// longer needs `unboxed_bitmaps`.

module {
  func.func @target(%a: i64, %b: f64, %c: i16, %d: !eco.value, %e: i64) -> i64 {
    eco.return %a : i64
  }

  func.func @sib0(%x: !eco.value, %self: !eco.value, %y: i64) -> i64 {
    eco.return %y : i64
  }

  func.func @sib1(%x: i64, %self: !eco.value, %y: i64) -> i64 {
    eco.return %y : i64
  }

  func.func @make(%a: i64, %b: f64, %c: i16, %d: !eco.value) -> !eco.value {
    %p = "eco.papCreate"(%a, %b) {
      function = @target, arity = 5 : i64, num_captured = 2 : i64,
      slot_kinds = array<i8: 1, 2>
    } : (i64, f64) -> !eco.value
    %q = "eco.papExtend"(%p, %c, %d) {
      remaining_arity = 3 : i64,
      newargs_unboxed_bitmap = 3 : i64,
      slot_kinds = array<i8: 3, 0>
    } : (!eco.value, i16, !eco.value) -> !eco.value
    return %q : !eco.value
  }

  func.func @group(%v: !eco.value, %n: i64) -> !eco.value {
    %g:2 = "eco.papCreateGroup"(%v, %n) {
      functions = [@sib0, @sib1],
      fast_evaluators = [@sib0, @sib1],
      arities = [3, 3],
      num_captured = [2, 2],
      slot_kinds = [array<i8: 0, 0>, array<i8: 1, 0>],
      capture_counts = [1, 1],
      cross_edges = [1, 0, 1, 0, 1, 1]
    } : (!eco.value, i64) -> (!eco.value, !eco.value)
    return %g#0 : !eco.value
  }
}

// CHECK: "eco.papCreate"
// CHECK-SAME: slot_kinds = array<i8: 1, 2>
// CHECK: "eco.papExtend"
// CHECK-SAME: slot_kinds = array<i8: 3, 0>
// CHECK: "eco.papCreateGroup"
// CHECK-SAME: slot_kinds = [array<i8: 0, 0>, array<i8: 1, 0>]
// CHECK-NOT: error
