// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// P4 capture path (HOF-elimination plan H4.1): a capture-carrying
// papCreate names its $cap clone (params = captures + params) in both
// `function` and `_fast_evaluator`. Multi-use elision must call that clone
// directly with the captures forwarded.

// CHECK-NOT: eco.papCreate
// CHECK-NOT: eco.papExtend
// CHECK: "eco.call"(%c5_i64, %c3_i64)
// CHECK: "eco.call"(%c5_i64, %c7_i64)
// CHECK: callee = @lam$cap

module {
  func.func private @lam$cap(%cap: i64, %x: i64) -> i64 {
    %r = eco.int.add %cap, %x : i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64
    %c7 = arith.constant 7 : i64

    %pap = "eco.papCreate"(%c5) {
      function = @lam$cap,
      _fast_evaluator = @lam$cap,
      arity = 2 : i64,
      num_captured = 1 : i64,
      slot_kinds = array<i8: 1>
    } : (i64) -> !eco.value

    %r1 = "eco.papExtend"(%pap, %c3) {
      remaining_arity = 1 : i64,
      slot_kinds = array<i8: 1>
    } : (!eco.value, i64) -> i64

    %r2 = "eco.papExtend"(%pap, %c7) {
      remaining_arity = 1 : i64,
      slot_kinds = array<i8: 1>
    } : (!eco.value, i64) -> i64

    %sum = eco.int.add %r1, %r2 : i64
    return %sum : i64
  }
}
