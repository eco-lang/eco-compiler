// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test i16 with wrong case_kind.

module {
  // CHECK: error: 'eco.case' op i16 scrutinee requires case_kind 'chr'
  func.func @i16_wrong_kind(%c: i16) {
    eco.case %c : i16 [65, 66] result_types [i16] {
      eco.return %c : i16
    }, {
      eco.return %c : i16
    } {case_kind = "int"}
  }
}
