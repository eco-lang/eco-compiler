// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case selecting the Nothing branch (tag 0).

module {
  func.func @main() -> i64 {
    // Create a Custom with tag 0 (Nothing - no fields)
    %nothing = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    // Pattern match - should select tag 0 branch
    eco.case %nothing [0, 1] {
      // Tag 0: Nothing case
      %msg = arith.constant 999 : i64
      eco.dbg %msg : i64
      eco.return
    }, {
      // Tag 1: Just case - should not be reached
      %msg = arith.constant 111 : i64
      eco.dbg %msg : i64
      eco.return
    }
    // CHECK: 999

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
