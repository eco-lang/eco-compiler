// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.unbox extracting Char (i32) values - Unicode code points.

module {
  func.func @main() -> i64 {
    // ASCII character 'A' = 65
    %char_A = arith.constant 65 : i16
    %boxed_A = eco.box %char_A : i16 -> !eco.value
    eco.dbg %boxed_A : !eco.value
    // CHECK: 'A'

    // Unbox and verify
    %unboxed_A = eco.unbox %boxed_A : !eco.value -> i16
    eco.dbg %unboxed_A : i16
    // CHECK: 'A'

    // Character 'z' = 122
    %char_z = arith.constant 122 : i16
    %boxed_z = eco.box %char_z : i16 -> !eco.value
    eco.dbg %boxed_z : !eco.value
    // CHECK: 'z'

    %unboxed_z = eco.unbox %boxed_z : !eco.value -> i16
    eco.dbg %unboxed_z : i16
    // CHECK: 'z'

    // Unicode: Greek letter alpha = U+03B1 = 945
    %char_alpha = arith.constant 945 : i16
    %boxed_alpha = eco.box %char_alpha : i16 -> !eco.value
    eco.dbg %boxed_alpha : !eco.value
    // CHECK: '\u03B1'

    %unboxed_alpha = eco.unbox %boxed_alpha : !eco.value -> i16
    eco.dbg %unboxed_alpha : i16
    // CHECK: '\u03B1'

    // Unicode: U+F800 (private use area) = 63488
    %char_emoji = arith.constant 63488 : i16
    %boxed_emoji = eco.box %char_emoji : i16 -> !eco.value
    eco.dbg %boxed_emoji : !eco.value
    // CHECK: '\uF800'

    %unboxed_emoji = eco.unbox %boxed_emoji : !eco.value -> i16
    eco.dbg %unboxed_emoji : i16
    // CHECK: '\uF800'

    // Newline character = 10
    %char_nl = arith.constant 10 : i16
    %boxed_nl = eco.box %char_nl : i16 -> !eco.value
    // Newline prints specially
    eco.dbg %boxed_nl : !eco.value
    // CHECK: '\n'

    // Space = 32
    %char_space = arith.constant 32 : i16
    %boxed_space = eco.box %char_space : i16 -> !eco.value
    eco.dbg %boxed_space : !eco.value
    // CHECK: ' '

    // Zero/null character = 0
    %char_null = arith.constant 0 : i16
    %boxed_null = eco.box %char_null : i16 -> !eco.value
    eco.dbg %boxed_null : !eco.value
    // CHECK: '\u0000'

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
