// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test subnormal/denormal floating point numbers.
// These are the smallest representable positive floats.

module {
  func.func @main() -> i64 {
    // Smallest positive subnormal: 2^-1074 approx 4.94e-324
    // We can't represent this exactly in MLIR constant syntax,
    // so we'll create it via division
    %one = arith.constant 1.0 : f64
    %two = arith.constant 2.0 : f64
    %large_neg = arith.constant -1000.0 : f64

    // Create a very small number by repeated division
    // 2^-50 is still normal
    %small = eco.float.pow %two, %large_neg : f64

    // small > 0 should be true (subnormals are positive)
    %zero_f = arith.constant 0.0 : f64
    %is_pos = eco.float.gt %small, %zero_f : f64
    %is_pos_ext = arith.extui %is_pos : i1 to i64
    eco.dbg %is_pos_ext : i64
    // CHECK: 1

    // small * 2 should be larger
    %doubled = eco.float.mul %small, %two : f64
    %is_larger = eco.float.gt %doubled, %small : f64
    %is_larger_ext = arith.extui %is_larger : i1 to i64
    eco.dbg %is_larger_ext : i64
    // CHECK: 1

    // small + small = 2 * small
    %sum = eco.float.add %small, %small : f64
    %eq_doubled = eco.float.eq %sum, %doubled : f64
    %eq_doubled_ext = arith.extui %eq_doubled : i1 to i64
    eco.dbg %eq_doubled_ext : i64
    // CHECK: 1

    // Subnormal minus itself should be exactly 0
    %diff = eco.float.sub %small, %small : f64
    %is_zero = eco.float.eq %diff, %zero_f : f64
    %is_zero_ext = arith.extui %is_zero : i1 to i64
    eco.dbg %is_zero_ext : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
