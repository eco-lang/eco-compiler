// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test valid scrutinee type / case_kind combinations for eco.case.

module {
  // CHECK: eco.case
  // eco.case is a terminator, so no func.return after it
  func.func @ctor_case_valid(%v: !eco.value) {
    eco.case %v : !eco.value [0, 1] result_types [!eco.value] {
      eco.return %v : !eco.value
    }, {
      eco.return %v : !eco.value
    } {case_kind = "ctor"}
  }

  // CHECK: eco.case
  func.func @int_case_valid(%x: i64) {
    eco.case %x : i64 [0, 1] result_types [i64] {
      %c0 = arith.constant 0 : i64
      eco.return %c0 : i64
    }, {
      %c1 = arith.constant 1 : i64
      eco.return %c1 : i64
    } {case_kind = "int"}
  }

  // CHECK: eco.case
  func.func @chr_case_valid(%c: i16) {
    eco.case %c : i16 [65, 66] result_types [i16] {
      eco.return %c : i16
    }, {
      eco.return %c : i16
    } {case_kind = "chr"}
  }

  // CHECK: eco.case
  func.func @bool_case_valid(%b: i1) {
    eco.case %b : i1 [0, 1] result_types [i1] {
      eco.return %b : i1
    }, {
      eco.return %b : i1
    } {case_kind = "bool"}
  }

  // CHECK: eco.case
  func.func @bool_ctor_case_valid(%b: i1) {
    // i1 with case_kind="ctor" - allowed for Chain lowering compatibility
    eco.case %b : i1 [0, 1] result_types [i1] {
      eco.return %b : i1
    }, {
      eco.return %b : i1
    } {case_kind = "ctor"}
  }
}
