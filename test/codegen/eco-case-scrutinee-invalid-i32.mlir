// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test unsupported scrutinee type (i32).

module {
  // CHECK: error: 'eco.case' op operand #0 must be eco value or primitive, but got 'i32'
  // eco.case is a terminator, so no func.return after it
  func.func @i32_not_allowed(%x: i32) {
    eco.case %x : i32 [0, 1] result_types [i32] {
      eco.return %x : i32
    }, {
      eco.return %x : i32
    } {case_kind = "int"}
  }
}
