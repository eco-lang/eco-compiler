// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that papExtend chains are fused when intermediate results have single use.

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

    // Create PAP with one captured arg
    %pap = "eco.papCreate"(%c1) {
      function = @add3,
      arity = 3 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // First extend (partial) - remaining 2, applying 1
    %pap2 = "eco.papExtend"(%pap, %c2) {
      remaining_arity = 2 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> !eco.value

    // Second extend (saturates) - chain should be fused then converted to call
    %result = "eco.papExtend"(%pap2, %c3) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.dbg %result : i64
    // CHECK: [eco.dbg] 6

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
