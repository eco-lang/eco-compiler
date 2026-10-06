// RUN: not %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// Phase 3D (plans/wide-object-tail-kind-words-phase-3.md 3D.5): papCreate's slot_kinds
// defaults to the empty array (the front end omits it on a zero-capture papCreate), so a
// papCreate with captures and no slot_kinds is rejected by the length check.

module {
  func.func @add_three_ints(%a: i64, %b: i64, %c: i64) -> i64 {
    %sum1 = eco.int.add %a, %b : i64
    %result = eco.int.add %sum1, %c : i64
    eco.return %result : i64
  }

  func.func @main() -> !eco.value {
    %i10 = arith.constant 10 : i64
    %i20 = arith.constant 20 : i64
    %pap = "eco.papCreate"(%i10, %i20) {
      function = @add_three_ints,
      arity = 3 : i64,
      num_captured = 2 : i64
    } : (i64, i64) -> !eco.value
    return %pap : !eco.value
  }
}

// CHECK: slot_kinds length (0) != capture count (2)
