// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that eco.case without result_types fails verification.
// CGEN_010 invariant: eco.case must have explicit result_types attribute.

module {
  // Use a void-returning function since eco.case is a terminator
  func.func @missing_result_types(%x: !eco.value) {
    // CHECK: error: 'eco.case' op requires 'result_types' (caseResultTypes) attribute; eco.case is always an expression form
    eco.case %x : !eco.value [0] {
      eco.return %x : !eco.value
    } {case_kind = "ctor"}
  }
}
