// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_string with various sizes.
// Tests different string allocation sizes.

module {
  func.func @main() -> i64 {
    // Allocate empty string (length 0)
    %s0 = eco.allocate_string {length = 0 : i64} : !eco.value
    eco.dbg %s0 : !eco.value
    // CHECK: ""

    // Allocate small string
    %s1 = eco.allocate_string {length = 1 : i64} : !eco.value
    eco.dbg %s1 : !eco.value
    // Uninitialized string has null bytes
    // CHECK: "\u0000"

    // Allocate medium string
    %s10 = eco.allocate_string {length = 10 : i64} : !eco.value
    eco.dbg %s10 : !eco.value
    // CHECK: "\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000"

    // Allocate larger string (just verify it prints without crashing)
    %s100 = eco.allocate_string {length = 100 : i64} : !eco.value
    eco.dbg %s100 : !eco.value
    // Skip checking the 100-char string content

    // Compare with actual string literal
    %literal = eco.string_literal "hello" : !eco.value
    eco.dbg %literal : !eco.value
    // CHECK: "hello"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
