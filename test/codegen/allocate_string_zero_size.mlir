// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_string with length 0 (empty string allocation).

module {
  func.func @main() -> i64 {
    // Allocate an empty string
    %empty = eco.allocate_string {length = 0 : i64} : !eco.value
    eco.dbg %empty : !eco.value
    // CHECK: ""

    // Allocate another empty string
    %empty2 = eco.allocate_string {length = 0 : i64} : !eco.value
    eco.dbg %empty2 : !eco.value
    // CHECK: ""

    // For comparison, allocate a non-empty string
    %str = eco.string_literal "hello" : !eco.value
    eco.dbg %str : !eco.value
    // CHECK: "hello"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
