// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with 0 fields (unit-like types, empty constructors).
// These are tag-only custom types without data.

module {
  func.func @main() -> i64 {
    // Empty constructor (tag 0, no fields)
    // Like () or a nullary constructor
    %empty0 = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %empty0 : !eco.value
    // CHECK: Ctor0

    // Different tag, still empty
    %empty1 = eco.construct() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %empty1 : !eco.value
    // CHECK: Ctor1

    // Third empty variant
    %empty2 = eco.construct() {tag = 2 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %empty2 : !eco.value
    // CHECK: Ctor2

    // Higher tag number
    %empty42 = eco.construct() {tag = 42 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %empty42 : !eco.value
    // CHECK: Ctor42

    // Test case on empty constructors
    eco.case %empty0 [0, 1, 2] {
      %r0 = arith.constant 100 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %r1 = arith.constant 101 : i64
      eco.dbg %r1 : i64
      eco.return
    }, {
      %r2 = arith.constant 102 : i64
      eco.dbg %r2 : i64
      eco.return
    }
    // CHECK: 100

    eco.case %empty2 [0, 1, 2] {
      %r0 = arith.constant 200 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %r1 = arith.constant 201 : i64
      eco.dbg %r1 : i64
      eco.return
    }, {
      %r2 = arith.constant 202 : i64
      eco.dbg %r2 : i64
      eco.return
    }
    // CHECK: 202

    // Wrap empty in another constructor (Just Empty)
    %just_empty = eco.construct(%empty0) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.dbg %just_empty : !eco.value
    // CHECK: Ctor1 Ctor0

    // Project the empty value back out
    %projected = eco.project %just_empty[0] : !eco.value -> !eco.value
    eco.dbg %projected : !eco.value
    // CHECK: Ctor0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
