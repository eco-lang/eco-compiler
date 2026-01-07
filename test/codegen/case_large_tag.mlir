// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.case with large tag values.
// Tests tag extraction from header with larger values.

module {
  func.func @main() -> i64 {
    %unit = eco.constant Unit : !eco.value

    // Create values with large tags
    %tag255 = eco.construct.custom(%unit) {tag = 255 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag1000 = eco.construct.custom(%unit) {tag = 1000 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    %tag32767 = eco.construct.custom(%unit) {tag = 32767 : i64, size = 1 : i64} : (!eco.value) -> !eco.value

    // Test with tag 255 (max 8-bit value)
    eco.case %tag255 [0, 255, 1000, 32767] {
      %c0 = arith.constant 0 : i64
      eco.dbg %c0 : i64
      eco.return
    }, {
      %c255 = arith.constant 255 : i64
      eco.dbg %c255 : i64
      eco.return
    }, {
      %c1000 = arith.constant 1000 : i64
      eco.dbg %c1000 : i64
      eco.return
    }, {
      %c32767 = arith.constant 32767 : i64
      eco.dbg %c32767 : i64
      eco.return
    }
    // CHECK: 255

    // Test with tag 1000
    eco.case %tag1000 [0, 255, 1000, 32767] {
      %c0 = arith.constant 0 : i64
      eco.dbg %c0 : i64
      eco.return
    }, {
      %c255 = arith.constant 255 : i64
      eco.dbg %c255 : i64
      eco.return
    }, {
      %c1000 = arith.constant 1000 : i64
      eco.dbg %c1000 : i64
      eco.return
    }, {
      %c32767 = arith.constant 32767 : i64
      eco.dbg %c32767 : i64
      eco.return
    }
    // CHECK: 1000

    // Test with tag 32767 (max 15-bit value)
    eco.case %tag32767 [0, 255, 1000, 32767] {
      %c0 = arith.constant 0 : i64
      eco.dbg %c0 : i64
      eco.return
    }, {
      %c255 = arith.constant 255 : i64
      eco.dbg %c255 : i64
      eco.return
    }, {
      %c1000 = arith.constant 1000 : i64
      eco.dbg %c1000 : i64
      eco.return
    }, {
      %c32767 = arith.constant 32767 : i64
      eco.dbg %c32767 : i64
      eco.return
    }
    // CHECK: 32767

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
