// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test multi-byte UTF-8 sequence cut off at end.
// e.g., \xC0 alone (2-byte sequence lead with no continuation)

module {
  func.func @main() -> i64 {
    // 2-byte sequence lead (C2-DF) without continuation
    // \xC2 expects one continuation byte
    %trunc2 = eco.string_literal "A\C2" : !eco.value
    eco.dbg %trunc2 : !eco.value
    // CHECK: [eco.dbg]

    // 3-byte sequence lead (E0-EF) without enough continuation
    // \xE0 expects two continuation bytes
    %trunc3 = eco.string_literal "B\E0\80" : !eco.value
    eco.dbg %trunc3 : !eco.value
    // CHECK: [eco.dbg]

    // Valid 2-byte sequence for comparison: \xC3\xA9 = é (U+00E9)
    %valid2 = eco.string_literal "\C3\A9" : !eco.value
    eco.dbg %valid2 : !eco.value
    // CHECK: [eco.dbg]

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
