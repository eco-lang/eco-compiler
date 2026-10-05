// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 2 (plans/wide-object-tail-kind-words-phase-2.md 2.1): `slot_kinds` must equal
// each operand's MLIR type kind (CGEN_003). Newarg 1 is an i64 (Int = 1) but slot_kinds
// says Float (2).

module {
  func.func @target(%a: i64, %b: i64, %c: i64) -> i64 {
    eco.return %a : i64
  }

  func.func @bad(%f: !eco.value, %a: i64, %b: i64) -> !eco.value {
    %q = "eco.papExtend"(%f, %a, %b) {
      remaining_arity = 3 : i64,
      slot_kinds = array<i8: 1, 2>
    } : (!eco.value, i64, i64) -> !eco.value
    return %q : !eco.value
  }
}

// CHECK: slot_kinds 2 does not match SSA type
