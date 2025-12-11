// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string literal with special characters and edge cases.

module {
  func.func @main() -> i64 {
    // Simple string for baseline
    %s1 = eco.string_literal "hello" : !eco.value
    eco.dbg %s1 : !eco.value
    // CHECK: "hello"

    // String with newline
    %s2 = eco.string_literal "line1\nline2" : !eco.value
    eco.dbg %s2 : !eco.value
    // CHECK: "line1

    // String with tab
    %s3 = eco.string_literal "col1\tcol2" : !eco.value
    eco.dbg %s3 : !eco.value
    // CHECK: "col1

    // Empty string
    %s4 = eco.string_literal "" : !eco.value
    eco.dbg %s4 : !eco.value
    // CHECK: ""

    // Single character
    %s5 = eco.string_literal "x" : !eco.value
    eco.dbg %s5 : !eco.value
    // CHECK: "x"

    // Longer string
    %s6 = eco.string_literal "the quick brown fox" : !eco.value
    eco.dbg %s6 : !eco.value
    // CHECK: "the quick brown fox"

    // String with spaces at boundaries
    %s7 = eco.string_literal " padded " : !eco.value
    eco.dbg %s7 : !eco.value
    // CHECK: " padded "

    // String with digits
    %s8 = eco.string_literal "abc123def" : !eco.value
    eco.dbg %s8 : !eco.value
    // CHECK: "abc123def"

    // Multiple words
    %s9 = eco.string_literal "hello world test" : !eco.value
    eco.dbg %s9 : !eco.value
    // CHECK: "hello world test"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
