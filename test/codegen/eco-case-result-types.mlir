// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test that eco.case with explicit result_types passes verification.
// This is a positive test for the CGEN_010 invariant.

module {
  func.func @case_expr(%x: !eco.value) -> !eco.value {
    // CHECK: eco.case %arg0 [0, 1] result_types [!eco.value]
    eco.case %x [0, 1] result_types [!eco.value] {
      eco.return %x : !eco.value
    }, {
      eco.return %x : !eco.value
    }
    func.return %x : !eco.value
  }
}
