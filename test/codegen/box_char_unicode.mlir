// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test character boxing with ASCII and Unicode code points.

module {
  func.func @main() -> i64 {
    // ASCII 'A' (65)
    %c0 = arith.constant 65 : i16
    %b0 = eco.box %c0 : i16 -> !eco.value
    eco.dbg %b0 : !eco.value
    // CHECK: 'A'

    // ASCII 'z' (122)
    %c1 = arith.constant 122 : i16
    %b1 = eco.box %c1 : i16 -> !eco.value
    eco.dbg %b1 : !eco.value
    // CHECK: 'z'

    // Space (32)
    %c2 = arith.constant 32 : i16
    %b2 = eco.box %c2 : i16 -> !eco.value
    eco.dbg %b2 : !eco.value
    // CHECK: ' '

    // Newline (10) - may print as escape or literal
    %c3 = arith.constant 10 : i16
    %b3 = eco.box %c3 : i16 -> !eco.value
    eco.dbg %b3 : !eco.value
    // CHECK: '

    // Greek lambda (955 = 0x03BB)
    %c4 = arith.constant 955 : i16
    %b4 = eco.box %c4 : i16 -> !eco.value
    eco.dbg %b4 : !eco.value
    // CHECK: '

    // Chinese character (20013 = 0x4E2D, meaning "middle")
    %c5 = arith.constant 20013 : i16
    %b5 = eco.box %c5 : i16 -> !eco.value
    eco.dbg %b5 : !eco.value
    // CHECK: '

    // Euro sign (8364 = 0x20AC)
    %c6 = arith.constant 8364 : i16
    %b6 = eco.box %c6 : i16 -> !eco.value
    eco.dbg %b6 : !eco.value
    // CHECK: '

    // Digit '0' (48)
    %c7 = arith.constant 48 : i16
    %b7 = eco.box %c7 : i16 -> !eco.value
    eco.dbg %b7 : !eco.value
    // CHECK: '0'

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
