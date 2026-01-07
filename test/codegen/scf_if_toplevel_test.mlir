// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test scf.if lowering for top-level case expressions (not inside joinpoints).
// These cases can be lowered to scf.if because their eco.return exits the
// enclosing function, not a joinpoint.

module {
  // Test 1: Simple 2-way case on boolean (true branch)
  func.func @test_true_branch() {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64

    // True = tag 1
    %true = eco.construct.custom() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %true [0, 1] {
      eco.dbg %c20 : i64
      eco.return
    }, {
      eco.dbg %c10 : i64
      eco.return
    }
    eco.return
  }

  // Test 2: Simple 2-way case on boolean (false branch)
  func.func @test_false_branch() {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64

    // False = tag 0
    %false = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %false [0, 1] {
      eco.dbg %c20 : i64
      eco.return
    }, {
      eco.dbg %c10 : i64
      eco.return
    }
    eco.return
  }

  func.func @main() -> i64 {
    func.call @test_true_branch() : () -> ()
    // CHECK: 10

    func.call @test_false_branch() : () -> ()
    // CHECK: 20

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
