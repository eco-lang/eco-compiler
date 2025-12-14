// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test result_types inference pass.
// These cases don't have explicit result_types - they should be inferred
// from the eco.return operands in each alternative.

module {
  // Test 1: Void case (no return values) - should get empty result_types
  // and be lowered to scf.if
  func.func @test_void_case() {
    %c30 = arith.constant 30 : i64
    %c40 = arith.constant 40 : i64

    %true = eco.construct() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %true [0, 1] {
      eco.dbg %c40 : i64
      eco.return
    }, {
      eco.dbg %c30 : i64
      eco.return
    }
    eco.return
  }

  // Test 2: Void case with false branch
  func.func @test_void_case_false() {
    %c50 = arith.constant 50 : i64
    %c60 = arith.constant 60 : i64

    %false = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %false [0, 1] {
      eco.dbg %c50 : i64
      eco.return
    }, {
      eco.dbg %c60 : i64
      eco.return
    }
    eco.return
  }

  func.func @main() -> i64 {
    func.call @test_void_case() : () -> ()
    // CHECK: 30

    func.call @test_void_case_false() : () -> ()
    // CHECK: 50

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
