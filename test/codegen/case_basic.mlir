// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test basic eco.case operation - pattern matching on constructor tag.

module {
  func.func @main() -> i64 {
    // Create a Custom with tag 1 (simulating Maybe.Just 42)
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %just = eco.construct.custom(%b42) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Pattern match on the constructor
    eco.case %just [0, 1] {
      // Tag 0: Nothing case
      %nothing_val = arith.constant 0 : i64
      eco.dbg %nothing_val : i64
      eco.return
    }, {
      // Tag 1: Just case - extract the value
      %inner = eco.project.custom %just[0] : !eco.value -> !eco.value
      eco.dbg %inner : !eco.value
      eco.return
    }
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
