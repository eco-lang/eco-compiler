// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Structural pin for P4 (HOF-elimination plan H4.1): a papCreate whose
// every use is a saturated typed-mode papExtend is erased and both uses
// become direct calls with the capture forwarded. (The harness matcher is
// substring/anywhere semantics: the two calls are distinguished by their
// argument constants.)

// CHECK-NOT: eco.papCreate
// CHECK-NOT: eco.papExtend
// CHECK: "eco.call"(%c5_i64, %c3_i64)
// CHECK: "eco.call"(%c5_i64, %c7_i64)

module {
  func.func @add(%a: i64, %b: i64) -> i64 {
    %sum = eco.int.add %a, %b : i64
    eco.return %sum : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64
    %c7 = arith.constant 7 : i64

    %pap = "eco.papCreate"(%c5) {
      function = @add,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 1 : i64
    } : (i64) -> !eco.value

    %r1 = "eco.papExtend"(%pap, %c3) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    %r2 = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 1 : i64,
      newargs_unboxed_bitmap = 1 : i64
    } : (!eco.value, i64) -> i64

    %sum = eco.int.add %r1, %r2 : i64
    return %sum : i64
  }
}
