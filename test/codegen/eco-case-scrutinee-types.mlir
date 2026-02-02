// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// Test valid scrutinee type / case_kind combinations for eco.case.

module {
  // CHECK: eco.case
  func.func @ctor_case_valid(%v: !eco.value) -> !eco.value {
    %result = eco.case %v : !eco.value [0, 1] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %v : !eco.value
    }, {
      eco.yield %v : !eco.value
    }
    return %result : !eco.value
  }

  // CHECK: eco.case
  func.func @int_case_valid(%x: i64) -> i64 {
    %result = eco.case %x : i64 [0, 1] -> (i64) {case_kind = "int"} {
      %c0 = arith.constant 0 : i64
      eco.yield %c0 : i64
    }, {
      %c1 = arith.constant 1 : i64
      eco.yield %c1 : i64
    }
    return %result : i64
  }

  // CHECK: eco.case
  func.func @chr_case_valid(%c: i16) -> i16 {
    %result = eco.case %c : i16 [65, 66] -> (i16) {case_kind = "chr"} {
      eco.yield %c : i16
    }, {
      eco.yield %c : i16
    }
    return %result : i16
  }

  // CHECK: eco.case
  func.func @bool_case_valid(%b: i1) -> i1 {
    %result = eco.case %b : i1 [0, 1] -> (i1) {case_kind = "bool"} {
      eco.yield %b : i1
    }, {
      eco.yield %b : i1
    }
    return %result : i1
  }

  // CHECK: eco.case
  func.func @bool_ctor_case_valid(%b: i1) -> i1 {
    // i1 with case_kind="ctor" - allowed for Chain lowering compatibility
    %result = eco.case %b : i1 [0, 1] -> (i1) {case_kind = "ctor"} {
      eco.yield %b : i1
    }, {
      eco.yield %b : i1
    }
    return %result : i1
  }
}
