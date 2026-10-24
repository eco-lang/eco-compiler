// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-7: the typed papExtend newarg check (CGEN_003, PapExtendOp::verifySymbolUses
// in EcoOps.cpp) walks the closure operand's defining ops back to an
// eco.papCreate and returns success silently as soon as the closure has no
// defining op (a block argument). Here the closure reaches the papExtend as
// the joinpoint parameter %clo, whose only incoming value is the papCreate of
// @target2. @target2's parameter 0 is !eco.value, but the typed papExtend
// passes an i64, the same mismatch that
// invalid_pap_extend_newarg_vs_evaluator_chain.mlir rejects when the papCreate
// is the direct operand. The verifier must report it here too.

module {
  func.func private @target2(%a: !eco.value, %b: !eco.value) -> !eco.value {
    eco.return %b : !eco.value
  }

  func.func @main() -> !eco.value {
    %p = "eco.papCreate"() {arity = 2 : i64, function = @target2, num_captured = 0 : i64, slot_kinds = array<i8>} : () -> !eco.value
    eco.joinpoint 0(%clo: !eco.value) {
      %c1 = arith.constant 1 : i64
      %q = "eco.papExtend"(%clo, %c1) {remaining_arity = 2 : i64, slot_kinds = array<i8: 1>} : (!eco.value, i64) -> !eco.value
      eco.return %q : !eco.value
    } continuation {
      eco.jump 0(%p : !eco.value)
    }
    %e = eco.constant Empty : !eco.value
    eco.return %e : !eco.value
  }
}

// CHECK: error: 'eco.papExtend' op {{.*}}newarg 0 has type 'i64'
