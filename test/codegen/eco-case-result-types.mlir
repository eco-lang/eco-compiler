// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test that eco.case with explicit result types passes verification.
// This is a positive test for the CGEN_010 invariant.

module {
  // CHECK: eco.case
  func.func @case_expr(%x: !eco.value) -> !eco.value {
    %result = eco.case %x : !eco.value [0, 1] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %x : !eco.value
    }, {
      eco.yield %x : !eco.value
    }
    return %result : !eco.value
  }
}
