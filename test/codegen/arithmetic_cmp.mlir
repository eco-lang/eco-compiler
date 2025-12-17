// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test comparison and min/max operations.

module {
  func.func @main() -> i64 {
    %i5 = arith.constant 5 : i64
    %i10 = arith.constant 10 : i64
    %i5b = arith.constant 5 : i64
    %f5 = arith.constant 5.0 : f64
    %f10 = arith.constant 10.0 : f64
    %f5b = arith.constant 5.0 : f64

    // eco.int.lt: 5 < 10 = True
    %lt = eco.int.lt %i5, %i10 : i64
    %blt = eco.box %lt : i1 -> !eco.value
    eco.dbg %blt : !eco.value
    // CHECK: True

    // eco.int.gt: 5 > 10 = False
    %gt = eco.int.gt %i5, %i10 : i64
    %bgt = eco.box %gt : i1 -> !eco.value
    eco.dbg %bgt : !eco.value
    // CHECK: False

    // eco.int.eq: 5 == 5 = True
    %eq = eco.int.eq %i5, %i5b : i64
    %beq = eco.box %eq : i1 -> !eco.value
    eco.dbg %beq : !eco.value
    // CHECK: True

    // eco.int.ne: 5 != 10 = True
    %ne = eco.int.ne %i5, %i10 : i64
    %bne = eco.box %ne : i1 -> !eco.value
    eco.dbg %bne : !eco.value
    // CHECK: True

    // eco.int.le: 5 <= 5 = True
    %le = eco.int.le %i5, %i5b : i64
    %ble = eco.box %le : i1 -> !eco.value
    eco.dbg %ble : !eco.value
    // CHECK: True

    // eco.int.ge: 10 >= 5 = True
    %ge = eco.int.ge %i10, %i5 : i64
    %bge = eco.box %ge : i1 -> !eco.value
    eco.dbg %bge : !eco.value
    // CHECK: True

    // eco.float.lt: 5.0 < 10.0 = True
    %flt = eco.float.lt %f5, %f10 : f64
    %bflt = eco.box %flt : i1 -> !eco.value
    eco.dbg %bflt : !eco.value
    // CHECK: True

    // eco.float.eq: 5.0 == 5.0 = True
    %feq = eco.float.eq %f5, %f5b : f64
    %bfeq = eco.box %feq : i1 -> !eco.value
    eco.dbg %bfeq : !eco.value
    // CHECK: True

    // eco.int.min: min 5 10 = 5
    %imin = eco.int.min %i5, %i10 : i64
    eco.dbg %imin : i64
    // CHECK: 5

    // eco.int.max: max 5 10 = 10
    %imax = eco.int.max %i5, %i10 : i64
    eco.dbg %imax : i64
    // CHECK: 10

    // eco.float.min: min 5.0 10.0 = 5.0
    %fmin = eco.float.min %f5, %f10 : f64
    eco.dbg %fmin : f64
    // CHECK: 5

    // eco.float.max: max 5.0 10.0 = 10.0
    %fmax = eco.float.max %f5, %f10 : f64
    eco.dbg %fmax : f64
    // CHECK: 10

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
