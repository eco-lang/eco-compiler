// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct with size=0 but non-zero tags.
// This represents enum variants with no data (like None, Nothing, etc.)

module {
  func.func @main() -> i64 {
    // Tag 0 with no fields (like () or Unit)
    %ctor0 = eco.construct() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %ctor0 : !eco.value
    // CHECK: Ctor0

    // Tag 1 with no fields (like Nothing in Maybe)
    %ctor1 = eco.construct() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %ctor1 : !eco.value
    // CHECK: Ctor1

    // Tag 2 with no fields
    %ctor2 = eco.construct() {tag = 2 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %ctor2 : !eco.value
    // CHECK: Ctor2

    // Tag 10 with no fields
    %ctor10 = eco.construct() {tag = 10 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %ctor10 : !eco.value
    // CHECK: Ctor10

    // Large tag with no fields
    %ctor100 = eco.construct() {tag = 100 : i64, size = 0 : i64} : () -> !eco.value
    eco.dbg %ctor100 : !eco.value
    // CHECK: Ctor100

    // Verify we can discriminate between them with case
    eco.case %ctor0 [0, 1, 2] {
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
    // CHECK: [eco.dbg] 100

    eco.case %ctor1 [0, 1, 2] {
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
    // CHECK: [eco.dbg] 201

    eco.case %ctor2 [0, 1, 2] {
      %r0 = arith.constant 300 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %r1 = arith.constant 301 : i64
      eco.dbg %r1 : i64
      eco.return
    }, {
      %r2 = arith.constant 302 : i64
      eco.dbg %r2 : i64
      eco.return
    }
    // CHECK: [eco.dbg] 302

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
