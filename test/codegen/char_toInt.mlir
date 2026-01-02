// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.char.toInt operation (Char.toCode).
// Converts i16 (char) to i64 (int).

module {
  func.func @main() -> i64 {
    // ASCII 'A' = 65
    %char_A = arith.constant 65 : i16
    %code_A = eco.char.toInt %char_A : i16 -> i64
    eco.dbg %code_A : i64
    // CHECK: 65

    // ASCII 'z' = 122
    %char_z = arith.constant 122 : i16
    %code_z = eco.char.toInt %char_z : i16 -> i64
    eco.dbg %code_z : i64
    // CHECK: 122

    // Null character = 0
    %char_null = arith.constant 0 : i16
    %code_null = eco.char.toInt %char_null : i16 -> i64
    eco.dbg %code_null : i64
    // CHECK: 0

    // Newline = 10
    %char_nl = arith.constant 10 : i16
    %code_nl = eco.char.toInt %char_nl : i16 -> i64
    eco.dbg %code_nl : i64
    // CHECK: 10

    // Space = 32
    %char_space = arith.constant 32 : i16
    %code_space = eco.char.toInt %char_space : i16 -> i64
    eco.dbg %code_space : i64
    // CHECK: 32

    // Greek alpha = 945 (0x03B1)
    %char_alpha = arith.constant 945 : i16
    %code_alpha = eco.char.toInt %char_alpha : i16 -> i64
    eco.dbg %code_alpha : i64
    // CHECK: 945

    // Maximum BMP value = 65535 (0xFFFF)
    %char_max = arith.constant 65535 : i16
    %code_max = eco.char.toInt %char_max : i16 -> i64
    eco.dbg %code_max : i64
    // CHECK: 65535

    // Test with 1000
    %char_1000 = arith.constant 1000 : i16
    %code_1000 = eco.char.toInt %char_1000 : i16 -> i64
    eco.dbg %code_1000 : i64
    // CHECK: 1000

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
