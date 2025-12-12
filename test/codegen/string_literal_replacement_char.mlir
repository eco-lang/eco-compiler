// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string literals with valid UTF-8 sequences.
// The string literal op should handle UTF-8 correctly.
// Invalid sequences would be replaced with U+FFFD in the lowering.

module {
  func.func @main() -> i64 {
    // Simple ASCII
    %ascii = eco.string_literal "hello" : !eco.value
    eco.dbg %ascii : !eco.value
    // CHECK: "hello"

    // UTF-8 with common Unicode
    %euro = eco.string_literal "100\E2\82\AC" : !eco.value
    eco.dbg %euro : !eco.value
    // CHECK: "100

    // UTF-8 with emoji (4-byte sequence)
    %smile = eco.string_literal "\F0\9F\98\80" : !eco.value
    eco.dbg %smile : !eco.value
    // CHECK: "

    // Mixed ASCII and UTF-8
    %mixed = eco.string_literal "a\C3\A9b" : !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: "a

    // Empty string
    %empty = eco.string_literal "" : !eco.value
    eco.dbg %empty : !eco.value
    // CHECK: ""

    // String with null in middle (if supported)
    %with_null = eco.string_literal "ab\00cd" : !eco.value
    eco.dbg %with_null : !eco.value
    // Output depends on implementation

    // Just verify test runs without crash
    %done = arith.constant 999 : i64
    eco.dbg %done : i64
    // CHECK: [eco.dbg] 999

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
