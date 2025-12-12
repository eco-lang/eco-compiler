// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test large int where float can't represent exactly.
// e.g., 2^53 + 1 can't be represented exactly in f64.

module {
  func.func @main() -> i64 {
    // Small values convert exactly
    %c1000 = arith.constant 1000 : i64
    %f1000 = eco.int.toFloat %c1000 : i64 -> f64
    %back1000 = eco.float.truncate %f1000 : f64 -> i64
    eco.dbg %back1000 : i64
    // CHECK: [eco.dbg] 1000

    // 2^52 = 4503599627370496 (exactly representable)
    %pow52 = arith.constant 4503599627370496 : i64
    %f52 = eco.int.toFloat %pow52 : i64 -> f64
    %back52 = eco.float.truncate %f52 : f64 -> i64
    eco.dbg %back52 : i64
    // CHECK: [eco.dbg] 4503599627370496

    // 2^53 = 9007199254740992 (exactly representable, last exact integer)
    %pow53 = arith.constant 9007199254740992 : i64
    %f53 = eco.int.toFloat %pow53 : i64 -> f64
    %back53 = eco.float.truncate %f53 : f64 -> i64
    eco.dbg %back53 : i64
    // CHECK: [eco.dbg] 9007199254740992

    // 2^53 + 1 = 9007199254740993 (NOT exactly representable)
    // Will round to 9007199254740992 when converted to float
    %pow53_plus1 = arith.constant 9007199254740993 : i64
    %f53_p1 = eco.int.toFloat %pow53_plus1 : i64 -> f64
    %back53_p1 = eco.float.truncate %f53_p1 : f64 -> i64
    // This will likely be 9007199254740992, showing precision loss
    eco.dbg %back53_p1 : i64
    // CHECK: [eco.dbg] 9007199254740992

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
