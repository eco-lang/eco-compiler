// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// P4 two-clone path (HOF-elimination plan H4.1): a capture-carrying
// papCreate advertises `_fast_evaluator` ($cap clone whose params are
// captures + params). Multi-use elision must target the $cap clone, not
// the $clo wrapper named in `function`.

// CHECK-NOT: eco.papCreate
// CHECK-NOT: eco.papExtend
// CHECK: "eco.call"(%c5_i64, %c3_i64)
// CHECK: "eco.call"(%c5_i64, %c7_i64)
// CHECK: callee = @lam$cap
// CHECK-NOT: callee = @lam$clo

module {
  func.func private @lam$cap(%cap: i64, %x: i64) -> i64 {
    %r = eco.int.add %cap, %x : i64
    eco.return %r : i64
  }

  func.func private @lam$clo(%clo: !eco.value, %x: i64) -> i64 {
    %c0 = arith.constant 0 : i64
    eco.return %c0 : i64
  }

  func.func @main() -> i64 {
    %c5 = arith.constant 5 : i64
    %c3 = arith.constant 3 : i64
    %c7 = arith.constant 7 : i64

    %pap = "eco.papCreate"(%c5) {
      function = @lam$clo,
      _fast_evaluator = @lam$cap,
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
