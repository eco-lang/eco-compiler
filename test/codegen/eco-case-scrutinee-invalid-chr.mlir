// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test i16 with wrong case_kind.

module {
  // CHECK: error: 'eco.case' op i16 scrutinee requires case_kind 'chr'
  func.func @i16_wrong_kind(%c: i16) -> i16 {
    %result = eco.case %c : i16 [65, 66] -> (i16) {case_kind = "int"} {
      eco.yield %c : i16
    }, {
      eco.yield %c : i16
    }
    return %result : i16
  }
}
