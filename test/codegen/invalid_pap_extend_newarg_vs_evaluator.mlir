// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// CGEN_003: a typed papExtend's newargs fill the evaluator's params, so their SSA types
// must be the target func.func's param types. Here an i64 is passed to an evaluator whose
// param is !eco.value (an erased type variable, as for `Task.succeed` applied to an Int
// through a let-bound alias): EcoPAPSimplify would turn the saturated extend into a direct
// call with the wrong signature ("Calling a function with a bad signature!" in LLVM).

module {
  func.func private @target(%a: !eco.value) -> !eco.value {
    eco.return %a : !eco.value
  }

  func.func @bad() -> !eco.value {
    %p = "eco.papCreate"() {arity = 1 : i64, function = @target, num_captured = 0 : i64, slot_kinds = array<i8>} : () -> !eco.value
    %c7 = arith.constant 7 : i64
    %r = "eco.papExtend"(%p, %c7) {remaining_arity = 1 : i64, slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
    eco.return %r : !eco.value
  }
}

// CHECK: CGEN_003: typed papExtend newarg 0 has type 'i64' but evaluator 'target' expects '!eco.value' at parameter 0
