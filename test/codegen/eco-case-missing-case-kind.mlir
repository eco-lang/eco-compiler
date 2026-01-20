// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that missing case_kind attribute is rejected.

module {
  // CHECK: error: 'eco.case' op requires attribute 'case_kind'
  func.func @missing_case_kind(%v: !eco.value) -> !eco.value {
    eco.case %v : !eco.value [0, 1] result_types [!eco.value] {
      eco.return %v : !eco.value
    }, {
      eco.return %v : !eco.value
    }
    func.return %v : !eco.value
  }
}
