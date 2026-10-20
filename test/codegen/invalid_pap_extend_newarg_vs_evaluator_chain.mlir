// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// CGEN_003 (chain walk): a typed papExtend's newargs fill the evaluator's params, so their
// SSA types must be the target func.func's param types; the second extend fills param 1.
// The partial extend in @chain checks the offset walk through earlier extends.

module {
  func.func private @target2(%a: i64, %b: !eco.value) -> !eco.value {
    eco.return %b : !eco.value
  }

  func.func @chain() -> !eco.value {
    %p = "eco.papCreate"() {arity = 2 : i64, function = @target2, num_captured = 0 : i64, slot_kinds = array<i8>} : () -> !eco.value
    %c1 = arith.constant 1 : i64
    %q = "eco.papExtend"(%p, %c1) {remaining_arity = 2 : i64, slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    %c2 = arith.constant 2 : i64
    %r = "eco.papExtend"(%q, %c2) {remaining_arity = 1 : i64, slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    eco.return %r : !eco.value
  }
}

// CHECK: CGEN_003: typed papExtend newarg 0 has type 'i64' but evaluator 'target2' expects '!eco.value' at parameter 1
