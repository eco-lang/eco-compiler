// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test pattern matching on nested structures using sequential cases.
// This is the flattened form that the decision tree compiler generates.
// Simulates matching: Just (Left 42)
//
// The compiler flattens nested patterns into sequential tests:
// 1. Test outer constructor (Nothing vs Just)
// 2. Extract inner value
// 3. Test inner constructor (Left vs Right)

module {
  func.func @main() -> i64 {
    // Create inner: Left 42 (tag=0, one field)
    %i42 = arith.constant 42 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %left = eco.construct.custom(%b42) {tag = 0 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Create outer: Just (Left 42) (tag=1, one field)
    %just_left = eco.construct.custom(%left) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // First case: Test outer constructor (Nothing=0, Just=1)
    eco.case %just_left [0, 1] {
      // Nothing case - print 0
      %n = arith.constant 0 : i64
      eco.dbg %n : i64
      eco.return
    }, {
      // Just case - continue to next test
      %one = arith.constant 1 : i64
      eco.dbg %one : i64
      eco.return
    }
    // CHECK: 1

    // Extract inner value (only valid after Just case)
    %inner = eco.project.custom %just_left[0] : !eco.value -> !eco.value

    // Second case: Test inner constructor (Left=0, Right=1)
    eco.case %inner [0, 1] {
      // Left case - extract and print value
      %val = eco.project.custom %inner[0] : !eco.value -> !eco.value
      eco.dbg %val : !eco.value
      eco.return
    }, {
      // Right case - print 999
      %r = arith.constant 999 : i64
      eco.dbg %r : i64
      eco.return
    }
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
