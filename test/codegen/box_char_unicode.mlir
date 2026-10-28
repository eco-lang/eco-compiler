// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test character boxing with ASCII and Unicode code points.

module {
  func.func @main() -> i64 {
    // ASCII 'A' (65)
    %c0 = arith.constant 65 : i32
    %b0 = eco.box %c0 : i32 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 'A'

    // ASCII 'z' (122)
    %c1 = arith.constant 122 : i32
    %b1 = eco.box %c1 : i32 -> !eco.value
    eco.dbg %b1 : !eco.value
    // CHECK: 'z'

    // Space (32)
    %c2 = arith.constant 32 : i32
    %b2 = eco.box %c2 : i32 -> !eco.value
    eco.dbg %b2 : !eco.value
    // CHECK: ' '

    // Newline (10) - may print as escape or literal
    %c3 = arith.constant 10 : i32
    %b3 = eco.box %c3 : i32 -> !eco.value
    eco.dbg %b3 : !eco.value
    // CHECK: '\n'

    // Greek lambda (955 = 0x03BB)
    %c4 = arith.constant 955 : i32
    %b4 = eco.box %c4 : i32 -> !eco.value
    eco.dbg %b4 : !eco.value
    // CHECK: 'λ'

    // Chinese character (20013 = 0x4E2D, meaning "middle")
    %c5 = arith.constant 20013 : i32
    %b5 = eco.box %c5 : i32 -> !eco.value
    eco.dbg %b5 : !eco.value
    // CHECK: '中'

    // Euro sign (8364 = 0x20AC)
    %c6 = arith.constant 8364 : i32
    %b6 = eco.box %c6 : i32 -> !eco.value
    eco.dbg %b6 : !eco.value
    // CHECK: '€'

    // Digit '0' (48)
    %c7 = arith.constant 48 : i32
    %b7 = eco.box %c7 : i32 -> !eco.value
    eco.dbg %b7 : !eco.value
    // CHECK: '0'

    // Astral: grinning face U+1F600 (128512) - beyond the BMP, needs the
    // full i32 code point
    %c8 = arith.constant 128512 : i32
    %b8 = eco.box %c8 : i32 -> !eco.value
    eco.dbg %b8 : !eco.value
    // CHECK: '😀'

    // Max code point U+10FFFF is a noncharacter; it still round-trips, so
    // check its code via unbox + toInt
    %c9 = arith.constant 1114111 : i32
    %b9 = eco.box %c9 : i32 -> !eco.value
    %u9 = eco.unbox %b9 : !eco.value -> i32
    %code9 = eco.char.toInt %u9 : i32 -> i64
    eco.dbg %code9 : i64
    // CHECK: 1114111

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
