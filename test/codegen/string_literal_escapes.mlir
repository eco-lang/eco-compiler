// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string literals with various escape sequences.

module {
  func.func @main() -> i64 {
    // Tab character
    %tab = eco.string_literal "a\09b" : !eco.value
    eco.dbg %tab : !eco.value
    // CHECK: "a

    // Newline character
    %newline = eco.string_literal "line1\0Aline2" : !eco.value
    eco.dbg %newline : !eco.value
    // CHECK: "line1

    // Carriage return
    %cr = eco.string_literal "hello\0Dworld" : !eco.value
    eco.dbg %cr : !eco.value
    // CHECK: "hello

    // Backslash
    %backslash = eco.string_literal "path\\5Cto\\5Cfile" : !eco.value
    eco.dbg %backslash : !eco.value
    // CHECK: "path

    // Double quote (escaped as hex)
    %quote = eco.string_literal "say \\22hello\\22" : !eco.value
    eco.dbg %quote : !eco.value
    // CHECK: "say

    // Null character
    %null_char = eco.string_literal "before\\00after" : !eco.value
    eco.dbg %null_char : !eco.value
    // CHECK: "before

    // Multiple escapes combined
    %combined = eco.string_literal "a\09b\0Ac" : !eco.value
    eco.dbg %combined : !eco.value
    // CHECK: "a

    // All printable ASCII
    %printable = eco.string_literal "!@#$%^&*()_+-=[]{}|;':,./<>?" : !eco.value
    eco.dbg %printable : !eco.value
    // CHECK: "!@#

    // Spaces
    %spaces = eco.string_literal "   " : !eco.value
    eco.dbg %spaces : !eco.value
    // CHECK: "   "

    // Mixed content
    %mixed = eco.string_literal "Hello, World!" : !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: "Hello, World!"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
