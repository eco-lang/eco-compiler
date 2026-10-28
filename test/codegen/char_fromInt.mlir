// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.char.fromInt operation (Char.fromCode).
// Converts i64 (int) to i32 (char, a Unicode code point). Elm semantics: a
// code outside 0..0x10FFFF becomes U+FFFD (65533); anything in range,
// surrogate code points included, passes through unchanged.

module {
  func.func @main() -> i64 {
    // Valid range: ASCII 'A' = 65
    %int_65 = arith.constant 65 : i64
    %char_A = eco.char.fromInt %int_65 : i64 -> i32
    // Convert back to int to verify
    %verify_A = eco.char.toInt %char_A : i32 -> i64
    eco.dbg %verify_A : i64
    // CHECK: 65

    // Valid range: null = 0
    %int_0 = arith.constant 0 : i64
    %char_null = eco.char.fromInt %int_0 : i64 -> i32
    %verify_null = eco.char.toInt %char_null : i32 -> i64
    eco.dbg %verify_null : i64
    // CHECK: 0

    // Valid range: max BMP = 65535
    %int_bmp = arith.constant 65535 : i64
    %char_bmp = eco.char.fromInt %int_bmp : i64 -> i32
    %verify_bmp = eco.char.toInt %char_bmp : i32 -> i64
    eco.dbg %verify_bmp : i64
    // CHECK: 65535

    // Out of range (negative): U+FFFD
    %neg = arith.constant -1 : i64
    %char_neg = eco.char.fromInt %neg : i64 -> i32
    %verify_neg = eco.char.toInt %char_neg : i32 -> i64
    eco.dbg %verify_neg : i64
    // CHECK: 65533

    // Astral (was clamped with the old 16-bit Char): passes through
    %astral = arith.constant 100000 : i64
    %char_astral = eco.char.fromInt %astral : i64 -> i32
    %verify_astral = eco.char.toInt %char_astral : i32 -> i64
    eco.dbg %verify_astral : i64
    // CHECK: 100000

    // Very negative: U+FFFD
    %very_neg = arith.constant -9223372036854775808 : i64
    %char_vneg = eco.char.fromInt %very_neg : i64 -> i32
    %verify_vneg = eco.char.toInt %char_vneg : i32 -> i64
    eco.dbg %verify_vneg : i64
    // CHECK: 65533

    // Just above the BMP: passes through
    %above_bmp = arith.constant 65536 : i64
    %char_abmp = eco.char.fromInt %above_bmp : i64 -> i32
    %verify_abmp = eco.char.toInt %char_abmp : i32 -> i64
    eco.dbg %verify_abmp : i64
    // CHECK: 65536

    // Emoji U+1F600
    %emoji = arith.constant 128512 : i64
    %char_emoji = eco.char.fromInt %emoji : i64 -> i32
    %verify_emoji = eco.char.toInt %char_emoji : i32 -> i64
    eco.dbg %verify_emoji : i64
    // CHECK: 128512

    // Max code point 0x10FFFF: passes through
    %int_max = arith.constant 1114111 : i64
    %char_max = eco.char.fromInt %int_max : i64 -> i32
    %verify_max = eco.char.toInt %char_max : i32 -> i64
    eco.dbg %verify_max : i64
    // CHECK: 1114111

    // Just above max (0x110000): U+FFFD
    %above_max = arith.constant 1114112 : i64
    %char_amax = eco.char.fromInt %above_max : i64 -> i32
    %verify_amax = eco.char.toInt %char_amax : i32 -> i64
    eco.dbg %verify_amax : i64
    // CHECK: 65533

    // Far above max, low 32 bits a valid code point (0x1_0000_0041): U+FFFD,
    // never the truncated 'A'
    %wraps = arith.constant 4294967361 : i64
    %char_wraps = eco.char.fromInt %wraps : i64 -> i32
    %verify_wraps = eco.char.toInt %char_wraps : i32 -> i64
    eco.dbg %verify_wraps : i64
    // CHECK: 65533

    // Surrogate code point 0xD800: passes through (as in Elm/JS)
    %surr = arith.constant 55296 : i64
    %char_surr = eco.char.fromInt %surr : i64 -> i32
    %verify_surr = eco.char.toInt %char_surr : i32 -> i64
    eco.dbg %verify_surr : i64
    // CHECK: 55296

    // Middle value: 1000
    %int_1000 = arith.constant 1000 : i64
    %char_1000 = eco.char.fromInt %int_1000 : i64 -> i32
    %verify_1000 = eco.char.toInt %char_1000 : i32 -> i64
    eco.dbg %verify_1000 : i64
    // CHECK: 1000

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
