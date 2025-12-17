// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test all 6 comparison predicates with NaN operands.
// eco.float.{lt,le,gt,ge,eq,ne} uses ordered comparisons - ALL return false when either operand is NaN.
// This includes 'ne' which uses ONE (ordered not-equal).

module {
  func.func @main() -> i64 {
    %nan = arith.constant 0x7FF8000000000000 : i64
    %nan_f = arith.bitcast %nan : i64 to f64
    %c1 = arith.constant 1.0 : f64

    // NaN < 1.0 -> false (ordered)
    %lt = eco.float.lt %nan_f, %c1 : f64
    %lt_i = arith.extui %lt : i1 to i64
    eco.dbg %lt_i : i64
    // CHECK: [eco.dbg] 0

    // NaN <= 1.0 -> false (ordered)
    %le = eco.float.le %nan_f, %c1 : f64
    %le_i = arith.extui %le : i1 to i64
    eco.dbg %le_i : i64
    // CHECK: [eco.dbg] 0

    // NaN > 1.0 -> false (ordered)
    %gt = eco.float.gt %nan_f, %c1 : f64
    %gt_i = arith.extui %gt : i1 to i64
    eco.dbg %gt_i : i64
    // CHECK: [eco.dbg] 0

    // NaN >= 1.0 -> false (ordered)
    %ge = eco.float.ge %nan_f, %c1 : f64
    %ge_i = arith.extui %ge : i1 to i64
    eco.dbg %ge_i : i64
    // CHECK: [eco.dbg] 0

    // NaN == 1.0 -> false (ordered)
    %eq = eco.float.eq %nan_f, %c1 : f64
    %eq_i = arith.extui %eq : i1 to i64
    eco.dbg %eq_i : i64
    // CHECK: [eco.dbg] 0

    // NaN != 1.0 -> false (ordered ONE returns false when NaN involved)
    %ne = eco.float.ne %nan_f, %c1 : f64
    %ne_i = arith.extui %ne : i1 to i64
    eco.dbg %ne_i : i64
    // CHECK: [eco.dbg] 0

    // NaN == NaN -> false
    %eq_nan = eco.float.eq %nan_f, %nan_f : f64
    %eq_nan_i = arith.extui %eq_nan : i1 to i64
    eco.dbg %eq_nan_i : i64
    // CHECK: [eco.dbg] 0

    // NaN != NaN -> false (ordered ONE)
    %ne_nan = eco.float.ne %nan_f, %nan_f : f64
    %ne_nan_i = arith.extui %ne_nan : i1 to i64
    eco.dbg %ne_nan_i : i64
    // CHECK: [eco.dbg] 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
