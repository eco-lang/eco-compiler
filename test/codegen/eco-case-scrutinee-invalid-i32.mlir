// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test unsupported scrutinee type (i32).

module {
  // CHECK: error: 'eco.case' op operand #0 must be eco value or primitive, but got 'i32'
  func.func @i32_not_allowed(%x: i32) -> i32 {
    %result = eco.case %x : i32 [0, 1] -> (i32) {case_kind = "int"} {
      eco.yield %x : i32
    }, {
      eco.yield %x : i32
    }
    return %result : i32
  }
}
