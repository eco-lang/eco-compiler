// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test deeply nested eco.case (4 levels of pattern matching).
// Simulates: case outer of Just (Left (Some (Value x))) -> x

module {
  func.func @main() -> i64 {
    // Build nested structure: Just(Left(Some(42)))
    // Level 4: Value 42 (tag=0, one boxed field)
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %value = eco.construct.custom(%b42) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Level 3: Some(Value 42) (tag=1, one field)
    %some = eco.construct.custom(%value) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Level 2: Left(Some(Value 42)) (tag=0, one field)
    %left = eco.construct.custom(%some) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Level 1: Just(Left(Some(Value 42))) (tag=1, one field)
    %just = eco.construct.custom(%left) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Level 1: case outer of Nothing (0) | Just (1)
    eco.case %just [0, 1] {
      // Nothing case
      %n = arith.constant -1 : i64
      eco.dbg %n : i64
      eco.return
    }, {
      // Just case - continue to level 2
      %one = arith.constant 1 : i64
      eco.dbg %one : i64
      eco.return
    }
    // CHECK: 1

    // Level 2: case inner of Left (0) | Right (1)
    %inner1 = eco.project.custom %just[0] : !eco.value -> !eco.value
    eco.case %inner1 [0, 1] {
      // Left case - continue to level 3
      %two = arith.constant 2 : i64
      eco.dbg %two : i64
      eco.return
    }, {
      // Right case
      %r = arith.constant -2 : i64
      eco.dbg %r : i64
      eco.return
    }
    // CHECK: 2

    // Level 3: case inner of None (0) | Some (1)
    %inner2 = eco.project.custom %inner1[0] : !eco.value -> !eco.value
    eco.case %inner2 [0, 1] {
      // None case
      %n = arith.constant -3 : i64
      eco.dbg %n : i64
      eco.return
    }, {
      // Some case - continue to level 4
      %three = arith.constant 3 : i64
      eco.dbg %three : i64
      eco.return
    }
    // CHECK: 3

    // Level 4: Extract the Value's content
    %inner3 = eco.project.custom %inner2[0] : !eco.value -> !eco.value
    %final = eco.project.custom %inner3[0] : !eco.value -> !eco.value
    eco.dbg %final : !eco.value
    // CHECK: 42

    // Now test a different path: Right
    %right = eco.construct.custom(%some) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %just2 = eco.construct.custom(%right) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    eco.case %just2 [0, 1] {
      %n = arith.constant -10 : i64
      eco.dbg %n : i64
      eco.return
    }, {
      %j = arith.constant 10 : i64
      eco.dbg %j : i64
      eco.return
    }
    // CHECK: 10

    %inner_r = eco.project.custom %just2[0] : !eco.value -> !eco.value
    eco.case %inner_r [0, 1] {
      %l = arith.constant 20 : i64
      eco.dbg %l : i64
      eco.return
    }, {
      // Right case
      %r = arith.constant 21 : i64
      eco.dbg %r : i64
      eco.return
    }
    // CHECK: 21

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
