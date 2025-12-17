// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test trigonometric functions: sin, cos, tan, asin, acos, atan, atan2, log

module {
  func.func @main() -> i64 {
    %pi = arith.constant 3.14159265358979323846 : f64
    %half_pi = arith.constant 1.5707963267948966 : f64
    %zero = arith.constant 0.0 : f64
    %one = arith.constant 1.0 : f64
    %e = arith.constant 2.718281828459045 : f64

    // sin(0) = 0
    %sin_zero = eco.float.sin %zero : f64
    // Should be very close to 0
    %sin_zero_abs = eco.float.abs %sin_zero : f64
    %sin_zero_ok = eco.float.lt %sin_zero_abs, %one : f64  // abs < 1 is a sanity check
    %sin_zero_i = arith.extui %sin_zero_ok : i1 to i64
    eco.dbg %sin_zero_i : i64
    // CHECK: [eco.dbg] 1

    // cos(0) = 1
    %cos_zero = eco.float.cos %zero : f64
    %cos_diff = eco.float.sub %cos_zero, %one : f64
    %cos_diff_abs = eco.float.abs %cos_diff : f64
    %epsilon = arith.constant 0.0001 : f64
    %cos_zero_ok = eco.float.lt %cos_diff_abs, %epsilon : f64
    %cos_zero_i = arith.extui %cos_zero_ok : i1 to i64
    eco.dbg %cos_zero_i : i64
    // CHECK: [eco.dbg] 1

    // tan(0) = 0
    %tan_zero = eco.float.tan %zero : f64
    %tan_zero_abs = eco.float.abs %tan_zero : f64
    %tan_zero_ok = eco.float.lt %tan_zero_abs, %epsilon : f64
    %tan_zero_i = arith.extui %tan_zero_ok : i1 to i64
    eco.dbg %tan_zero_i : i64
    // CHECK: [eco.dbg] 1

    // asin(0) = 0
    %asin_zero = eco.float.asin %zero : f64
    %asin_zero_abs = eco.float.abs %asin_zero : f64
    %asin_zero_ok = eco.float.lt %asin_zero_abs, %epsilon : f64
    %asin_zero_i = arith.extui %asin_zero_ok : i1 to i64
    eco.dbg %asin_zero_i : i64
    // CHECK: [eco.dbg] 1

    // acos(1) = 0
    %acos_one = eco.float.acos %one : f64
    %acos_one_abs = eco.float.abs %acos_one : f64
    %acos_one_ok = eco.float.lt %acos_one_abs, %epsilon : f64
    %acos_one_i = arith.extui %acos_one_ok : i1 to i64
    eco.dbg %acos_one_i : i64
    // CHECK: [eco.dbg] 1

    // atan(0) = 0
    %atan_zero = eco.float.atan %zero : f64
    %atan_zero_abs = eco.float.abs %atan_zero : f64
    %atan_zero_ok = eco.float.lt %atan_zero_abs, %epsilon : f64
    %atan_zero_i = arith.extui %atan_zero_ok : i1 to i64
    eco.dbg %atan_zero_i : i64
    // CHECK: [eco.dbg] 1

    // atan2(1, 1) = pi/4
    %atan2_1_1 = eco.float.atan2 %one, %one : f64
    %quarter_pi = arith.constant 0.7853981633974483 : f64
    %atan2_diff = eco.float.sub %atan2_1_1, %quarter_pi : f64
    %atan2_diff_abs = eco.float.abs %atan2_diff : f64
    %atan2_ok = eco.float.lt %atan2_diff_abs, %epsilon : f64
    %atan2_i = arith.extui %atan2_ok : i1 to i64
    eco.dbg %atan2_i : i64
    // CHECK: [eco.dbg] 1

    // log(e) = 1
    %log_e = eco.float.log %e : f64
    %log_diff = eco.float.sub %log_e, %one : f64
    %log_diff_abs = eco.float.abs %log_diff : f64
    %log_ok = eco.float.lt %log_diff_abs, %epsilon : f64
    %log_i = arith.extui %log_ok : i1 to i64
    eco.dbg %log_i : i64
    // CHECK: [eco.dbg] 1

    // log(1) = 0
    %log_one = eco.float.log %one : f64
    %log_one_abs = eco.float.abs %log_one : f64
    %log_one_ok = eco.float.lt %log_one_abs, %epsilon : f64
    %log_one_i = arith.extui %log_one_ok : i1 to i64
    eco.dbg %log_one_i : i64
    // CHECK: [eco.dbg] 1

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
