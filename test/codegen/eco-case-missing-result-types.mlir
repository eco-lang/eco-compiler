// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that eco.case without result_types fails parsing.
// The new syntax requires -> (types) for result types.

module {
  // CHECK: error: expected '->'
  // Missing -> (types) in the syntax
  func.func @missing_result_types(%x: !eco.value) -> !eco.value {
    %result = eco.case %x : !eco.value [0] {case_kind = "ctor"} {
      eco.yield %x : !eco.value
    }
    return %result : !eco.value
  }
}
