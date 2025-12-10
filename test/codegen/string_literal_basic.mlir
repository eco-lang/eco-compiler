// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.string_literal with basic ASCII strings.

module {
  func.func @main() -> i64 {
    // Simple greeting
    %hello = eco.string_literal "Hello" : !eco.value
    eco.dbg %hello : !eco.value
    // CHECK: "Hello"

    // Single character string
    %single = eco.string_literal "X" : !eco.value
    eco.dbg %single : !eco.value
    // CHECK: "X"

    // Longer string
    %longer = eco.string_literal "Hello, World!" : !eco.value
    eco.dbg %longer : !eco.value
    // CHECK: "Hello, World!"

    // String with spaces
    %spaces = eco.string_literal "one two three" : !eco.value
    eco.dbg %spaces : !eco.value
    // CHECK: "one two three"

    // String with numbers
    %nums = eco.string_literal "abc123xyz" : !eco.value
    eco.dbg %nums : !eco.value
    // CHECK: "abc123xyz"

    // String with punctuation
    %punct = eco.string_literal "Hello! How are you?" : !eco.value
    eco.dbg %punct : !eco.value
    // CHECK: "Hello! How are you?"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
