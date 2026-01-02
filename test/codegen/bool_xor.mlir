// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.bool.xor operation - truth table and properties.

module {
  func.func @main() -> i64 {
    %true = arith.constant true
    %false = arith.constant false

    // Truth table: T XOR T = F
    %tt = eco.bool.xor %true, %true : i1
    %boxed1 = eco.box %tt : i1 -> !eco.value
    eco.dbg %boxed1 : !eco.value
    // CHECK: False

    // Truth table: T XOR F = T
    %tf = eco.bool.xor %true, %false : i1
    %boxed2 = eco.box %tf : i1 -> !eco.value
    eco.dbg %boxed2 : !eco.value
    // CHECK: True

    // Truth table: F XOR T = T
    %ft = eco.bool.xor %false, %true : i1
    %boxed3 = eco.box %ft : i1 -> !eco.value
    eco.dbg %boxed3 : !eco.value
    // CHECK: True

    // Truth table: F XOR F = F
    %ff = eco.bool.xor %false, %false : i1
    %boxed4 = eco.box %ff : i1 -> !eco.value
    eco.dbg %boxed4 : !eco.value
    // CHECK: False

    // Identity: x XOR false = x (with x = true)
    %id1 = eco.bool.xor %true, %false : i1
    %boxed5 = eco.box %id1 : i1 -> !eco.value
    eco.dbg %boxed5 : !eco.value
    // CHECK: True

    // Identity: x XOR false = x (with x = false)
    %id2 = eco.bool.xor %false, %false : i1
    %boxed6 = eco.box %id2 : i1 -> !eco.value
    eco.dbg %boxed6 : !eco.value
    // CHECK: False

    // Self-inverse: x XOR x = false (with x = true)
    %self1 = eco.bool.xor %true, %true : i1
    %boxed7 = eco.box %self1 : i1 -> !eco.value
    eco.dbg %boxed7 : !eco.value
    // CHECK: False

    // Self-inverse: x XOR x = false (with x = false)
    %self2 = eco.bool.xor %false, %false : i1
    %boxed8 = eco.box %self2 : i1 -> !eco.value
    eco.dbg %boxed8 : !eco.value
    // CHECK: False

    // x XOR true = NOT x (with x = true)
    %not1 = eco.bool.xor %true, %true : i1
    %boxed9 = eco.box %not1 : i1 -> !eco.value
    eco.dbg %boxed9 : !eco.value
    // CHECK: False

    // x XOR true = NOT x (with x = false)
    %not2 = eco.bool.xor %false, %true : i1
    %boxed10 = eco.box %not2 : i1 -> !eco.value
    eco.dbg %boxed10 : !eco.value
    // CHECK: True

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
