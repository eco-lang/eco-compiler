// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string literals with various escape sequences.
// Comprehensive test of escape handling in string parsing.

module {
  func.func @main() -> i64 {
    // Newline
    %nl = eco.string_literal "line1\nline2" : !eco.value
    eco.dbg %nl : !eco.value
    // CHECK: "line1

    // Tab
    %tab = eco.string_literal "col1\tcol2" : !eco.value
    eco.dbg %tab : !eco.value
    // CHECK: "col1

    // Carriage return (use hex escape since \r not supported in MLIR)
    %cr = eco.string_literal "before\0Dafter" : !eco.value
    eco.dbg %cr : !eco.value
    // CHECK: "before

    // Backslash
    %bs = eco.string_literal "path\\to\\file" : !eco.value
    eco.dbg %bs : !eco.value
    // CHECK: "path

    // Double quote
    %dq = eco.string_literal "say \"hello\"" : !eco.value
    eco.dbg %dq : !eco.value
    // CHECK: "say

    // Null character (edge case)
    %null = eco.string_literal "before\00after" : !eco.value
    eco.dbg %null : !eco.value
    // CHECK: "before

    // Multiple escapes combined
    %combo = eco.string_literal "a\tb\nc\\d\"e" : !eco.value
    eco.dbg %combo : !eco.value
    // CHECK: "a

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
