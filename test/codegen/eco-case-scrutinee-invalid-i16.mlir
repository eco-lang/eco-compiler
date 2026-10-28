// RUN: not %ecoc %s 2>&1 | %FileCheck %s
//
// Test unsupported scrutinee type (i16). Elm Char is an i32 code point
// (Eco_Char = I<32>), so i32 is now a valid "chr" scrutinee; i16 is no longer
// any Elm primitive and must be rejected by the operand type constraint.

module {
  // CHECK: error: 'eco.case' op operand #0 must be eco value or primitive, but got 'i16'
  func.func @i16_not_allowed(%x: i16) -> i16 {
    %result = eco.case %x : i16 [0, 1] -> (i16) {case_kind = "int"} {
      eco.yield %x : i16
    }, {
      eco.yield %x : i16
    }
    return %result : i16
  }
}
