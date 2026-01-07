// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case with many branches.
// Simulates a custom type with 8 constructors.

module {
  func.func @main() -> i64 {
    // Create values with different tags (0-7)
    %val0 = eco.construct.custom() {tag = 0 : i64, size = 0 : i64} : () -> !eco.value
    %val1 = eco.construct.custom() {tag = 1 : i64, size = 0 : i64} : () -> !eco.value
    %val2 = eco.construct.custom() {tag = 2 : i64, size = 0 : i64} : () -> !eco.value
    %val3 = eco.construct.custom() {tag = 3 : i64, size = 0 : i64} : () -> !eco.value
    %val4 = eco.construct.custom() {tag = 4 : i64, size = 0 : i64} : () -> !eco.value
    %val5 = eco.construct.custom() {tag = 5 : i64, size = 0 : i64} : () -> !eco.value
    %val6 = eco.construct.custom() {tag = 6 : i64, size = 0 : i64} : () -> !eco.value
    %val7 = eco.construct.custom() {tag = 7 : i64, size = 0 : i64} : () -> !eco.value

    // Test case on tag 0
    eco.case %val0 [0, 1, 2, 3, 4, 5, 6, 7] {
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
    }, {
      %r3 = arith.constant 103 : i64
      eco.dbg %r3 : i64
      eco.return
    }, {
      %r4 = arith.constant 104 : i64
      eco.dbg %r4 : i64
      eco.return
    }, {
      %r5 = arith.constant 105 : i64
      eco.dbg %r5 : i64
      eco.return
    }, {
      %r6 = arith.constant 106 : i64
      eco.dbg %r6 : i64
      eco.return
    }, {
      %r7 = arith.constant 107 : i64
      eco.dbg %r7 : i64
      eco.return
    }
    // CHECK: 100

    // Test case on tag 4
    eco.case %val4 [0, 1, 2, 3, 4, 5, 6, 7] {
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
    }, {
      %r3 = arith.constant 203 : i64
      eco.dbg %r3 : i64
      eco.return
    }, {
      %r4 = arith.constant 204 : i64
      eco.dbg %r4 : i64
      eco.return
    }, {
      %r5 = arith.constant 205 : i64
      eco.dbg %r5 : i64
      eco.return
    }, {
      %r6 = arith.constant 206 : i64
      eco.dbg %r6 : i64
      eco.return
    }, {
      %r7 = arith.constant 207 : i64
      eco.dbg %r7 : i64
      eco.return
    }
    // CHECK: 204

    // Test case on tag 7 (last branch)
    eco.case %val7 [0, 1, 2, 3, 4, 5, 6, 7] {
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
    }, {
      %r3 = arith.constant 303 : i64
      eco.dbg %r3 : i64
      eco.return
    }, {
      %r4 = arith.constant 304 : i64
      eco.dbg %r4 : i64
      eco.return
    }, {
      %r5 = arith.constant 305 : i64
      eco.dbg %r5 : i64
      eco.return
    }, {
      %r6 = arith.constant 306 : i64
      eco.dbg %r6 : i64
      eco.return
    }, {
      %r7 = arith.constant 307 : i64
      eco.dbg %r7 : i64
      eco.return
    }
    // CHECK: 307

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
