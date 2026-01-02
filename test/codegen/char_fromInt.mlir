// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.char.fromInt operation (Char.fromCode).
// Converts i64 (int) to i16 (char) with clamping to [0, 0xFFFF].

module {
  func.func @main() -> i64 {
    // Valid range: ASCII 'A' = 65
    %int_65 = arith.constant 65 : i64
    %char_A = eco.char.fromInt %int_65 : i64 -> i16
    // Convert back to int to verify
    %verify_A = eco.char.toInt %char_A : i16 -> i64
    eco.dbg %verify_A : i64
    // CHECK: 65

    // Valid range: null = 0
    %int_0 = arith.constant 0 : i64
    %char_null = eco.char.fromInt %int_0 : i64 -> i16
    %verify_null = eco.char.toInt %char_null : i16 -> i64
    eco.dbg %verify_null : i64
    // CHECK: 0

    // Valid range: max BMP = 65535
    %int_max = arith.constant 65535 : i64
    %char_max = eco.char.fromInt %int_max : i64 -> i16
    %verify_max = eco.char.toInt %char_max : i16 -> i64
    eco.dbg %verify_max : i64
    // CHECK: 65535

    // Out of range (negative): should clamp to 0
    %neg = arith.constant -1 : i64
    %char_neg = eco.char.fromInt %neg : i64 -> i16
    %verify_neg = eco.char.toInt %char_neg : i16 -> i64
    eco.dbg %verify_neg : i64
    // CHECK: 0

    // Out of range (too large): should clamp to 65535
    %too_large = arith.constant 100000 : i64
    %char_large = eco.char.fromInt %too_large : i64 -> i16
    %verify_large = eco.char.toInt %char_large : i16 -> i64
    eco.dbg %verify_large : i64
    // CHECK: 65535

    // Very negative: should clamp to 0
    %very_neg = arith.constant -9223372036854775808 : i64
    %char_vneg = eco.char.fromInt %very_neg : i64 -> i16
    %verify_vneg = eco.char.toInt %char_vneg : i16 -> i64
    eco.dbg %verify_vneg : i64
    // CHECK: 0

    // Just above max: should clamp to 65535
    %above_max = arith.constant 65536 : i64
    %char_amax = eco.char.fromInt %above_max : i64 -> i16
    %verify_amax = eco.char.toInt %char_amax : i16 -> i64
    eco.dbg %verify_amax : i64
    // CHECK: 65535

    // Middle value: 1000
    %int_1000 = arith.constant 1000 : i64
    %char_1000 = eco.char.fromInt %int_1000 : i64 -> i16
    %verify_1000 = eco.char.toInt %char_1000 : i16 -> i64
    eco.dbg %verify_1000 : i64
    // CHECK: 1000

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
