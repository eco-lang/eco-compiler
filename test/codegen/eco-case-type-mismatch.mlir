// RUN: %ecoc %s 2>&1 | %FileCheck %s
//
// Test that eco.case with mismatched eco.return types fails verification.
// CGEN_010 invariant: eco.return operand types must match result_types.

module {
  func.func @type_mismatch(%x: !eco.value) -> !eco.value {
    // CHECK: error: 'eco.case' op alternative 0 eco.return operand 0 has type 'i64' but result_types specifies '!eco.value'
    eco.case %x : !eco.value [0] result_types [!eco.value] {
      %c = arith.constant 0 : i64
      eco.return %c : i64
    } {case_kind = "ctor"}
    func.return %x : !eco.value
  }
}
