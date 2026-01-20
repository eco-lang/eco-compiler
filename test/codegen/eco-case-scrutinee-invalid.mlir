// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test invalid scrutinee type / case_kind combinations for eco.case.

module {
  // CHECK: error: 'eco.case' op i64 scrutinee requires case_kind 'int'
  func.func @i64_wrong_kind(%x: i64) {
    eco.case %x : i64 [0, 1] result_types [i64] {
      eco.return %x : i64
    }, {
      eco.return %x : i64
    } {case_kind = "ctor"}
  }
}
