// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that missing case_kind attribute is rejected.

module {
  // CHECK: error: 'eco.case' op requires attribute 'case_kind'
  func.func @missing_case_kind(%v: !eco.value) -> !eco.value {
    // Empty attr-dict means no case_kind - should fail verification
    %result = eco.case %v : !eco.value [0, 1] -> (!eco.value) {} {
      eco.yield %v : !eco.value
    }, {
      eco.yield %v : !eco.value
    }
    return %result : !eco.value
  }
}
