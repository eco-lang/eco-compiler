// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip: fromInt(toInt(c)) == c for valid chars.
// Verifies that char.toInt and char.fromInt are inverses.

module {
  func.func @main() -> i64 {
    // Test various valid characters

    // 'A' = 65
    %c1 = arith.constant 65 : i16
    %code1 = eco.char.toInt %c1 : i16 -> i64
    %rt1 = eco.char.fromInt %code1 : i64 -> i16
    %verify1 = eco.char.toInt %rt1 : i16 -> i64
    eco.dbg %verify1 : i64
    // CHECK: 65

    // Null = 0
    %c2 = arith.constant 0 : i16
    %code2 = eco.char.toInt %c2 : i16 -> i64
    %rt2 = eco.char.fromInt %code2 : i64 -> i16
    %verify2 = eco.char.toInt %rt2 : i16 -> i64
    eco.dbg %verify2 : i64
    // CHECK: 0

    // Max BMP = 65535
    %c3 = arith.constant 65535 : i16
    %code3 = eco.char.toInt %c3 : i16 -> i64
    %rt3 = eco.char.fromInt %code3 : i64 -> i16
    %verify3 = eco.char.toInt %rt3 : i16 -> i64
    eco.dbg %verify3 : i64
    // CHECK: 65535

    // Greek alpha = 945
    %c4 = arith.constant 945 : i16
    %code4 = eco.char.toInt %c4 : i16 -> i64
    %rt4 = eco.char.fromInt %code4 : i64 -> i16
    %verify4 = eco.char.toInt %rt4 : i16 -> i64
    eco.dbg %verify4 : i64
    // CHECK: 945

    // Newline = 10
    %c5 = arith.constant 10 : i16
    %code5 = eco.char.toInt %c5 : i16 -> i64
    %rt5 = eco.char.fromInt %code5 : i64 -> i16
    %verify5 = eco.char.toInt %rt5 : i16 -> i64
    eco.dbg %verify5 : i64
    // CHECK: 10

    // 'z' = 122
    %c6 = arith.constant 122 : i16
    %code6 = eco.char.toInt %c6 : i16 -> i64
    %rt6 = eco.char.fromInt %code6 : i64 -> i16
    %verify6 = eco.char.toInt %rt6 : i16 -> i64
    eco.dbg %verify6 : i64
    // CHECK: 122

    // 1000
    %c7 = arith.constant 1000 : i16
    %code7 = eco.char.toInt %c7 : i16 -> i64
    %rt7 = eco.char.fromInt %code7 : i64 -> i16
    %verify7 = eco.char.toInt %rt7 : i16 -> i64
    eco.dbg %verify7 : i64
    // CHECK: 1000

    // 32767 (half of max)
    %c8 = arith.constant 32767 : i16
    %code8 = eco.char.toInt %c8 : i16 -> i64
    %rt8 = eco.char.fromInt %code8 : i64 -> i16
    %verify8 = eco.char.toInt %rt8 : i16 -> i64
    eco.dbg %verify8 : i64
    // CHECK: 32767

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
