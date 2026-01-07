// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case with non-contiguous (sparse) tag values.
// Tags: [0, 10, 100, 1000] - tests switch generation with gaps.

module {
  func.func @main() -> i64 {
    %unit = eco.constant Unit : !eco.value

    // Create values with different sparse tags
    %tag0 = eco.construct.custom(%unit) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag10 = eco.construct.custom(%unit) {tag = 10 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag100 = eco.construct.custom(%unit) {tag = 100 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1000 = eco.construct.custom(%unit) {tag = 1000 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Test case on tag 0
    eco.case %tag0 [0, 10, 100, 1000] {
      %c1 = arith.constant 1 : i64
      eco.dbg %c1 : i64
      eco.return
    }, {
      %c2 = arith.constant 2 : i64
      eco.dbg %c2 : i64
      eco.return
    }, {
      %c3 = arith.constant 3 : i64
      eco.dbg %c3 : i64
      eco.return
    }, {
      %c4 = arith.constant 4 : i64
      eco.dbg %c4 : i64
      eco.return
    }
    // CHECK: 1

    // Test case on tag 10
    eco.case %tag10 [0, 10, 100, 1000] {
      %c1 = arith.constant 1 : i64
      eco.dbg %c1 : i64
      eco.return
    }, {
      %c2 = arith.constant 2 : i64
      eco.dbg %c2 : i64
      eco.return
    }, {
      %c3 = arith.constant 3 : i64
      eco.dbg %c3 : i64
      eco.return
    }, {
      %c4 = arith.constant 4 : i64
      eco.dbg %c4 : i64
      eco.return
    }
    // CHECK: 2

    // Test case on tag 100
    eco.case %tag100 [0, 10, 100, 1000] {
      %c1 = arith.constant 1 : i64
      eco.dbg %c1 : i64
      eco.return
    }, {
      %c2 = arith.constant 2 : i64
      eco.dbg %c2 : i64
      eco.return
    }, {
      %c3 = arith.constant 3 : i64
      eco.dbg %c3 : i64
      eco.return
    }, {
      %c4 = arith.constant 4 : i64
      eco.dbg %c4 : i64
      eco.return
    }
    // CHECK: 3

    // Test case on tag 1000
    eco.case %tag1000 [0, 10, 100, 1000] {
      %c1 = arith.constant 1 : i64
      eco.dbg %c1 : i64
      eco.return
    }, {
      %c2 = arith.constant 2 : i64
      eco.dbg %c2 : i64
      eco.return
    }, {
      %c3 = arith.constant 3 : i64
      eco.dbg %c3 : i64
      eco.return
    }, {
      %c4 = arith.constant 4 : i64
      eco.dbg %c4 : i64
      eco.return
    }
    // CHECK: 4

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
