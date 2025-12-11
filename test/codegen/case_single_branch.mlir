// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case with only one alternative.
// This is a degenerate but valid case.

module {
  func.func @main() -> i64 {
    // Create a value with tag 0
    %val0 = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    // Case with single alternative matching tag 0
    eco.case %val0 [0] {
      %c1 = arith.constant 100 : i64
      eco.dbg %c1 : i64
      eco.return
    }
    // CHECK: 100

    // Create value with tag 5
    %val5 = eco.construct() {tag = 5 : i64, size = 0 : i64} : () -> !eco.value

    // Case with single alternative matching tag 5
    eco.case %val5 [5] {
      %c2 = arith.constant 200 : i64
      eco.dbg %c2 : i64
      eco.return
    }
    // CHECK: 200

    // Create value with tag 99
    %val99 = eco.construct() {tag = 99 : i64, size = 0 : i64} : () -> !eco.value

    // Case with single alternative matching tag 99
    eco.case %val99 [99] {
      %c3 = arith.constant 300 : i64
      eco.dbg %c3 : i64
      eco.return
    }
    // CHECK: 300

    // Single branch case with a field
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %with_field = eco.construct(%b42) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.case %with_field [0] {
      %field = eco.project %with_field[0] : !eco.value -> !eco.value
      eco.dbg %field : !eco.value
      eco.return
    }
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
