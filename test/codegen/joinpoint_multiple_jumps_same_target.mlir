// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test multiple branches jumping to the same joinpoint.
// This tests the joinpoint block handling in the lowering.

module {
  func.func @main() -> i64 {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    // Create values for case discrimination
    %b10 = eco.box %c10 : i64 -> !eco.value
    %b20 = eco.box %c20 : i64 -> !eco.value
    %b30 = eco.box %c30 : i64 -> !eco.value

    // Create different tagged values
    %tag0 = eco.construct(%b10) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1 = eco.construct(%b20) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag2 = eco.construct(%b30) {tag = 2 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Test: Multiple case branches with value passing through joinpoint
    eco.joinpoint 0(%result1: i64) {
      eco.dbg %result1 : i64
      eco.return
    } continuation {
      // Case where multiple branches can jump to joinpoint 0
      eco.case %tag0 [0, 1, 2] {
        // Tag 0 - jump with 100
        %v100 = arith.constant 100 : i64
        eco.jump 0(%v100 : i64)
      }, {
        // Tag 1 - jump with 200
        %v200 = arith.constant 200 : i64
        eco.jump 0(%v200 : i64)
      }, {
        // Tag 2 - jump with 300
        %v300 = arith.constant 300 : i64
        eco.jump 0(%v300 : i64)
      }
      eco.return
    }
    // Should print 100 (tag 0)
    // CHECK: 100

    // Now test with tag1
    eco.joinpoint 1(%result2: i64) {
      eco.dbg %result2 : i64
      eco.return
    } continuation {
      eco.case %tag1 [0, 1, 2] {
        %v100 = arith.constant 100 : i64
        eco.jump 1(%v100 : i64)
      }, {
        %v200 = arith.constant 200 : i64
        eco.jump 1(%v200 : i64)
      }, {
        %v300 = arith.constant 300 : i64
        eco.jump 1(%v300 : i64)
      }
      eco.return
    }
    // Should print 200 (tag 1)
    // CHECK: 200

    // Test with tag2
    eco.joinpoint 2(%result3: i64) {
      eco.dbg %result3 : i64
      eco.return
    } continuation {
      eco.case %tag2 [0, 1, 2] {
        %v100 = arith.constant 100 : i64
        eco.jump 2(%v100 : i64)
      }, {
        %v200 = arith.constant 200 : i64
        eco.jump 2(%v200 : i64)
      }, {
        %v300 = arith.constant 300 : i64
        eco.jump 2(%v300 : i64)
      }
      eco.return
    }
    // Should print 300 (tag 2)
    // CHECK: 300

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
