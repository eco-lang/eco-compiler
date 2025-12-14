// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test scf.index_switch lowering for case expressions with 3+ alternatives.

module {
  // Test 1: 3-way case on enum (void)
  func.func @test_3way_void() {
    %c10 = arith.constant 10 : i64
    %c20 = arith.constant 20 : i64
    %c30 = arith.constant 30 : i64

    // Create a tag=1 value
    %val = eco.construct() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %val [0, 1, 2] {
      eco.dbg %c10 : i64
      eco.return
    }, {
      eco.dbg %c20 : i64
      eco.return
    }, {
      eco.dbg %c30 : i64
      eco.return
    }
    eco.return
  }

  // Test 2: 3-way case, different tag
  func.func @test_3way_tag2() {
    %c40 = arith.constant 40 : i64
    %c50 = arith.constant 50 : i64
    %c60 = arith.constant 60 : i64

    // Create a tag=2 value
    %val = eco.construct() {tag = 2 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %val [0, 1, 2] {
      eco.dbg %c40 : i64
      eco.return
    }, {
      eco.dbg %c50 : i64
      eco.return
    }, {
      eco.dbg %c60 : i64
      eco.return
    }
    eco.return
  }

  // Test 3: 4-way case
  func.func @test_4way() {
    %c1 = arith.constant 1 : i64
    %c2 = arith.constant 2 : i64
    %c3 = arith.constant 3 : i64
    %c4 = arith.constant 4 : i64

    // Create a tag=3 value
    %val = eco.construct() {tag = 3 : i64, size = 0 : i64} : () -> !eco.value

    eco.case %val [0, 1, 2, 3] {
      eco.dbg %c1 : i64
      eco.return
    }, {
      eco.dbg %c2 : i64
      eco.return
    }, {
      eco.dbg %c3 : i64
      eco.return
    }, {
      eco.dbg %c4 : i64
      eco.return
    }
    eco.return
  }

  func.func @main() -> i64 {
    func.call @test_3way_void() : () -> ()
    // CHECK: 20

    func.call @test_3way_tag2() : () -> ()
    // CHECK: 60

    func.call @test_4way() : () -> ()
    // CHECK: 4

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
