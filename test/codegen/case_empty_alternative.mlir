// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test case with explicitly empty region (just return).
// Tests empty region handling in CaseOpLowering.

module {
  func.func @main() -> i64 {
    %unit = eco.constant Unit : !eco.value

    // Create variants
    %tag0 = eco.construct(%unit) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1 = eco.construct(%unit) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Case with minimal branches - just return immediately
    eco.case %tag0 [0, 1] {
      %c100 = arith.constant 100 : i64
      eco.dbg %c100 : i64
      eco.return
    }, {
      %c200 = arith.constant 200 : i64
      eco.dbg %c200 : i64
      eco.return
    }
    // CHECK: [eco.dbg] 100

    // Test the other branch
    eco.case %tag1 [0, 1] {
      %c300 = arith.constant 300 : i64
      eco.dbg %c300 : i64
      eco.return
    }, {
      %c400 = arith.constant 400 : i64
      eco.dbg %c400 : i64
      eco.return
    }
    // CHECK: [eco.dbg] 400

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
