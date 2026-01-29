// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that closures with multiple uses are NOT incorrectly optimized.

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %sum = eco.int.add %a, %b : i64
    eco.return %sum : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64
    %c7 = arith.constant 7 : i64

    // Create PAP - will be used TWICE
    %pap = "eco.papCreate"(%c5) {
      function = @add,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    // Use 1: 5 + 3 = 8
    %r1 = "eco.papExtend"(%pap, %c3) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    // Use 2: 5 + 7 = 12
    %r2 = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    eco.dbg %r1 : i64
    eco.dbg %r2 : i64
    // CHECK: [eco.dbg] 8
    // CHECK: [eco.dbg] 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
