// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.string_literal with empty and single-character strings.

module {
  func.func @main() -> i64 {
    // Empty string
    %empty = eco.string_literal "" : !eco.value
    eco.dbg %empty : !eco.value
    // CHECK: ""

    // Single ASCII character
    %single = eco.string_literal "a" : !eco.value
    eco.dbg %single : !eco.value
    // CHECK: "a"

    // Single space
    %space = eco.string_literal " " : !eco.value
    eco.dbg %space : !eco.value
    // CHECK: " "

    // Single newline
    %newline = eco.string_literal "\0A" : !eco.value
    eco.dbg %newline : !eco.value
    // CHECK: "

    // Single tab
    %tab = eco.string_literal "\09" : !eco.value
    eco.dbg %tab : !eco.value
    // CHECK: "

    // Single null byte (edge case)
    %null = eco.string_literal "\00" : !eco.value
    eco.dbg %null : !eco.value
    // CHECK: "

    // Single multi-byte unicode (3-byte UTF-8)
    %euro = eco.string_literal "\E2\82\AC" : !eco.value
    eco.dbg %euro : !eco.value
    // CHECK: "

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
