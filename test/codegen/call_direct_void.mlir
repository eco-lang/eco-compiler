// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.call with void return (no results).
// Functions that only have side effects.

module {
  // A void function that just prints
  func.func @print_hello() {
    %msg = eco.string_literal "hello from void function" : !eco.value
    eco.dbg %msg : !eco.value
    return
  }

  // A void function that prints an argument
  func.func @print_value(%x: !eco.value) {
    eco.dbg %x : !eco.value
    return
  }

  // A void function with multiple args
  func.func @print_two(%x: !eco.value, %y: !eco.value) {
    eco.dbg %x : !eco.value
    eco.dbg %y : !eco.value
    return
  }

  func.func @main() -> i64 {
    // Call void function with no args (using generic syntax for void return)
    "eco.call"() {callee = @print_hello} : () -> ()
    // CHECK: "hello from void function"

    // Call void function with one arg
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    "eco.call"(%b42) {callee = @print_value} : (!eco.value) -> ()
    // CHECK: 42

    // Call void function with two args
    %i100 = arith.constant 100 : i64
    %i200 = arith.constant 200 : i64
    %b100 = eco.box %i100 : i64 -> !eco.value
    %b200 = eco.box %i200 : i64 -> !eco.value
    "eco.call"(%b100, %b200) {callee = @print_two} : (!eco.value, !eco.value) -> ()
    // CHECK: 100
    // CHECK: 200

    // Call void function multiple times
    "eco.call"() {callee = @print_hello} : () -> ()
    // CHECK: "hello from void function"
    "eco.call"() {callee = @print_hello} : () -> ()
    // CHECK: "hello from void function"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
