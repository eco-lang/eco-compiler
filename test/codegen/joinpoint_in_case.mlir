// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test joinpoint defined inside a case branch.
// This is the reverse of case_in_joinpoint.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value

    // Create a Just value
    %just = eco.construct(%b10) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Case dispatch
    eco.case %just [0, 1] {
      // Nothing branch
      %r = arith.constant 0 : i64
      eco.dbg %r : i64
      eco.return
    }, {
      // Just branch - define a joinpoint inside
      %payload = eco.project %just[0] : !eco.value -> !eco.value
      %init = eco.unbox %payload : !eco.value -> i64

      // Simple joinpoint test inside case branch
      eco.joinpoint 0(%val: i64) {
        // Double the value and print
        %doubled = eco.int.mul %val, %val : i64
        eco.dbg %doubled : i64
        eco.return
      } continuation {
        eco.jump 0(%init : i64)
      }
      eco.return
    }
    // 10 * 10 = 100
    // CHECK: 100

    %ret = arith.constant 0 : i64
    return %ret : i64
  }
}
