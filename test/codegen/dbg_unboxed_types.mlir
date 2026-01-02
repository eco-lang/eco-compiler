// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.dbg with all unboxed primitive types.
// Tests type dispatch in DbgOpLowering.

module {
  func.func @main() -> i64 {
    // Test i64 (Int)
    %int_val = arith.constant 42 : i64
    eco.dbg %int_val : i64
    // CHECK: 42

    %int_neg = arith.constant -123 : i64
    eco.dbg %int_neg : i64
    // CHECK: -123

    %int_max = arith.constant 9223372036854775807 : i64
    eco.dbg %int_max : i64
    // CHECK: 9223372036854775807

    // Test f64 (Float)
    %float_val = arith.constant 3.14159 : f64
    eco.dbg %float_val : f64
    // CHECK: 3.14159

    %float_neg = arith.constant -2.718 : f64
    eco.dbg %float_neg : f64
    // CHECK: -2.718

    %float_inf = arith.constant 0x7FF0000000000000 : f64
    eco.dbg %float_inf : f64
    // CHECK: inf

    // Test i32 (Char)
    %char_A = arith.constant 65 : i16
    eco.dbg %char_A : i16
    // CHECK: 'A'

    %char_newline = arith.constant 10 : i16
    eco.dbg %char_newline : i16
    // CHECK: '\n'

    %char_unicode = arith.constant 945 : i16  // Greek alpha
    eco.dbg %char_unicode : i16
    // CHECK: '\u03B1'

    // Test i1 (Bool) - via boxing since direct i1 dbg may not work
    %bool_true = arith.constant true
    %boxed_true = eco.box %bool_true : i1 -> !eco.value
    eco.dbg %boxed_true : !eco.value
    // CHECK: True

    %bool_false = arith.constant false
    %boxed_false = eco.box %bool_false : i1 -> !eco.value
    eco.dbg %boxed_false : !eco.value
    // CHECK: False

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
