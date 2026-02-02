// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test invalid scrutinee type / case_kind combinations for eco.case.

module {
  // CHECK: error: 'eco.case' op i64 scrutinee requires case_kind 'int'
  func.func @i64_wrong_kind(%x: i64) -> i64 {
    %result = eco.case %x : i64 [0, 1] -> (i64) {case_kind = "ctor"} {
      eco.yield %x : i64
    }, {
      eco.yield %x : i64
    }
    return %result : i64
  }
}
