// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test that eco.case with explicit result_types passes verification.
// This is a positive test for the CGEN_010 invariant.

module {
  func.func @case_expr(%x: !eco.value) -> !eco.value {
    // CHECK: eco.case %arg0 : !eco.value [0, 1] result_types [!eco.value]
    eco.case %x : !eco.value [0, 1] result_types [!eco.value] {
      eco.return %x : !eco.value
    }, {
      eco.return %x : !eco.value
    } {case_kind = "ctor"}
    func.return %x : !eco.value
  }
}
