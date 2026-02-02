// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that eco.case with mismatched eco.yield types fails verification.
// CGEN_010 invariant: eco.yield operand types must match result types.

module {
  func.func @type_mismatch(%x: !eco.value) -> !eco.value {
    // CHECK: error: 'eco.case' op alternative 0 eco.yield operand 0 has type 'i64' but eco.case result 0 has type '!eco.value'
    %result = eco.case %x : !eco.value [0] -> (!eco.value) {case_kind = "ctor"} {
      %c = arith.constant 0 : i64
      eco.yield %c : i64
    }
    return %result : !eco.value
  }
}
