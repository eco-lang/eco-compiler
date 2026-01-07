// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case where every branch jumps to the same joinpoint.
// All branches are terminators (eco.jump).
//
// This is a design constraint of the eco.case op.

module {
  func.func @main() -> i64 {
    %unit = eco.constant Unit : !eco.value

    // Create variants with tags 0, 1, 2
    %tag0 = eco.construct.custom(%unit) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1 = eco.construct.custom(%unit) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag2 = eco.construct.custom(%unit) {tag = 2 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Joinpoint that receives a value computed in each branch
    eco.joinpoint 0(%result: i64) {
      eco.dbg %result : i64
      eco.return
    } continuation {
      // First test: tag0 should jump with 100
      eco.case %tag0 [0, 1, 2] {
        %c100 = arith.constant 100 : i64
        eco.jump 0(%c100 : i64)
      }, {
        %c200 = arith.constant 200 : i64
        eco.jump 0(%c200 : i64)
      }, {
        %c300 = arith.constant 300 : i64
        eco.jump 0(%c300 : i64)
      }
      eco.return
    }
    // CHECK: 100

    // Second test: tag1 should jump with 200
    eco.joinpoint 1(%result2: i64) {
      eco.dbg %result2 : i64
      eco.return
    } continuation {
      eco.case %tag1 [0, 1, 2] {
        %c100 = arith.constant 100 : i64
        eco.jump 1(%c100 : i64)
      }, {
        %c200 = arith.constant 200 : i64
        eco.jump 1(%c200 : i64)
      }, {
        %c300 = arith.constant 300 : i64
        eco.jump 1(%c300 : i64)
      }
      eco.return
    }
    // CHECK: 200

    // Third test: tag2 should jump with 300
    eco.joinpoint 2(%result3: i64) {
      eco.dbg %result3 : i64
      eco.return
    } continuation {
      eco.case %tag2 [0, 1, 2] {
        %c100 = arith.constant 100 : i64
        eco.jump 2(%c100 : i64)
      }, {
        %c200 = arith.constant 200 : i64
        eco.jump 2(%c200 : i64)
      }, {
        %c300 = arith.constant 300 : i64
        eco.jump 2(%c300 : i64)
      }
      eco.return
    }
    // CHECK: 300

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
