// RUN: not %ecoc %s 2>&1 | %FileCheck %s
//
// Test an i32 (Char) scrutinee with the wrong case_kind.

module {
  // CHECK: error: 'eco.case' op i32 (Char) scrutinee requires case_kind 'chr'
  func.func @char_wrong_kind(%c: i32) -> i32 {
    %result = eco.case %c : i32 [65, 66] -> (i32) {case_kind = "int"} {
      eco.yield %c : i32
    }, {
      eco.yield %c : i32
    }
    return %result : i32
  }
}
