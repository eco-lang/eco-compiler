// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test sequential eco.case operations (not truly nested).

module {
  func.func @main() -> i64 {
    // First case: tag 1
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %val1 = eco.construct.custom(%b42) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.case %val1 [0, 1] {
      %n = arith.constant 0 : i64
      eco.dbg %n : i64
      eco.return
    }, {
      %one = arith.constant 1 : i64
      eco.dbg %one : i64
      eco.return
    }
    // CHECK: 1

    // Second case: tag 0
    %val2 = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %val2 [0, 1] {
      %two = arith.constant 2 : i64
      eco.dbg %two : i64
      eco.return
    }, {
      %three = arith.constant 3 : i64
      eco.dbg %three : i64
      eco.return
    }
    // CHECK: 2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
