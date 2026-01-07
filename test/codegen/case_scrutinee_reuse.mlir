// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test using scrutinee value multiple times after case.
// Tests scrutinee replacement correctness.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value

    // Create a Just(10)
    %just10 = eco.construct.custom(%b10) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Case on the value, but also use scrutinee inside branches
    eco.case %just10 [0, 1] {
      // Nothing branch
      %c0 = arith.constant 0 : i64
      eco.dbg %c0 : i64
      eco.return
    }, {
      // Just branch - project from the SAME scrutinee
      %payload1 = eco.project.custom %just10[0] : !eco.value -> !eco.value
      %val1 = eco.unbox %payload1 : !eco.value -> i64
      eco.dbg %val1 : i64

      // Use scrutinee again
      %payload2 = eco.project.custom %just10[0] : !eco.value -> !eco.value
      %val2 = eco.unbox %payload2 : !eco.value -> i64
      eco.dbg %val2 : i64

      eco.return
    }
    // CHECK: [eco.dbg] 10
    // CHECK: [eco.dbg] 10

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
