// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case with exhaustive pattern matching.
// Tests that case correctly matches each tag to its corresponding branch.
// Note: eco.case doesn't support wildcard/default - all tags must be listed.

module {
  func.func @main() -> i64 {
    // Create values with various tags
    %val0 = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    %val1 = eco.construct.custom() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value
    %val2 = eco.construct.custom() {tag = 2 : i64, size = 0 : i64} : () -> !eco.value

    // Case that handles tags 0, 1, 2 explicitly
    eco.case %val0 [0, 1, 2] {
      // Tag 0 case
      %r0 = arith.constant 1000 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      // Tag 1 case
      %r1 = arith.constant 1001 : i64
      eco.dbg %r1 : i64
      eco.return
    }, {
      // Tag 2 case
      %r2 = arith.constant 1002 : i64
      eco.dbg %r2 : i64
      eco.return
    }
    // CHECK: 1000

    // Same case, but with tag 1
    eco.case %val1 [0, 1, 2] {
      %r0 = arith.constant 2000 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %r1 = arith.constant 2001 : i64
      eco.dbg %r1 : i64
      eco.return
    }, {
      %r2 = arith.constant 2002 : i64
      eco.dbg %r2 : i64
      eco.return
    }
    // CHECK: 2001

    // Same case, but with tag 2
    eco.case %val2 [0, 1, 2] {
      %r0 = arith.constant 3000 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %r1 = arith.constant 3001 : i64
      eco.dbg %r1 : i64
      eco.return
    }, {
      %r2 = arith.constant 3002 : i64
      eco.dbg %r2 : i64
      eco.return
    }
    // CHECK: 3002

    // Test with non-contiguous tags (0, 5, 10)
    %val5 = eco.construct.custom() {tag = 5 : i64, size = 0 : i64} : () -> !eco.value
    eco.case %val5 [0, 5, 10] {
      %r0 = arith.constant 4000 : i64
      eco.dbg %r0 : i64
      eco.return
    }, {
      %r5 = arith.constant 4005 : i64
      eco.dbg %r5 : i64
      eco.return
    }, {
      %r10 = arith.constant 4010 : i64
      eco.dbg %r10 : i64
      eco.return
    }
    // CHECK: 4005

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
