// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.call with musttail=true attribute for tail call semantics.
// The musttail attribute indicates the call must be a proper tail call.

module {
  // Helper function that adds two boxed integers
  func.func @add_two(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %va = eco.unbox %a : !eco.value -> i64
    %vb = eco.unbox %b : !eco.value -> i64
    %sum = eco.int.add %va, %vb : i64
    %result = eco.box %sum : i64 -> !eco.value
    eco.return %result : !eco.value
  }

  // Function that makes a tail call
  func.func @tail_caller(%x: !eco.value, %y: !eco.value) -> !eco.value {
    // This should be compiled as a tail call (using generic syntax for musttail)
    %result = "eco.call"(%x, %y) {callee = @add_two, musttail = true} : (!eco.value, !eco.value) -> !eco.value
    eco.return %result : !eco.value
  }

  func.func @main() -> i64 {
    %i10 = arith.constant 10 : i64
    %i25 = arith.constant 25 : i64
    %b10 = eco.box %i10 : i64 -> !eco.value
    %b25 = eco.box %i25 : i64 -> !eco.value

    // Call through tail_caller: 10 + 25 = 35
    %result = "eco.call"(%b10, %b25) {callee = @tail_caller} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result : !eco.value
    // CHECK: 35

    // Multiple tail calls
    %i5 = arith.constant 5 : i64
    %i7 = arith.constant 7 : i64
    %b5 = eco.box %i5 : i64 -> !eco.value
    %b7 = eco.box %i7 : i64 -> !eco.value

    %result2 = "eco.call"(%b5, %b7) {callee = @tail_caller} : (!eco.value, !eco.value) -> !eco.value
    eco.dbg %result2 : !eco.value
    // CHECK: 12

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
