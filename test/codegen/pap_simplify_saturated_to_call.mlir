// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that saturated papCreate+papExtend is optimized to a direct call.
// The optimization should eliminate closure allocation.

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %sum = eco.int.add %a, %b : i64
    eco.return %sum : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c7 = arith.constant 7 : i64

    // Create PAP with one captured arg
    %pap = "eco.papCreate"(%c5) {
      function = @add,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // Saturate with second arg - should become: eco.call @add(%c5, %c7)
    %result = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.dbg %result : i64
    // CHECK: [eco.dbg] 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
