// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.bool.and operation - truth table and properties.

module {
  func.func @main() -> i64 {
    %true = arith.constant true
    %false = arith.constant false

    // Truth table: T AND T = T
    %tt = eco.bool.and %true, %true : i1
    %boxed1 = eco.box %tt : i1 -> !eco.value
    eco.dbg %boxed1 : !eco.value
    // CHECK: True

    // Truth table: T AND F = F
    %tf = eco.bool.and %true, %false : i1
    %boxed2 = eco.box %tf : i1 -> !eco.value
    eco.dbg %boxed2 : !eco.value
    // CHECK: False

    // Truth table: F AND T = F
    %ft = eco.bool.and %false, %true : i1
    %boxed3 = eco.box %ft : i1 -> !eco.value
    eco.dbg %boxed3 : !eco.value
    // CHECK: False

    // Truth table: F AND F = F
    %ff = eco.bool.and %false, %false : i1
    %boxed4 = eco.box %ff : i1 -> !eco.value
    eco.dbg %boxed4 : !eco.value
    // CHECK: False

    // Identity: x AND true = x (with x = true)
    %id1 = eco.bool.and %true, %true : i1
    %boxed5 = eco.box %id1 : i1 -> !eco.value
    eco.dbg %boxed5 : !eco.value
    // CHECK: True

    // Identity: x AND true = x (with x = false)
    %id2 = eco.bool.and %false, %true : i1
    %boxed6 = eco.box %id2 : i1 -> !eco.value
    eco.dbg %boxed6 : !eco.value
    // CHECK: False

    // Annihilator: x AND false = false (with x = true)
    %ann1 = eco.bool.and %true, %false : i1
    %boxed7 = eco.box %ann1 : i1 -> !eco.value
    eco.dbg %boxed7 : !eco.value
    // CHECK: False

    // Idempotence: x AND x = x (with x = true)
    %idem1 = eco.bool.and %true, %true : i1
    %boxed8 = eco.box %idem1 : i1 -> !eco.value
    eco.dbg %boxed8 : !eco.value
    // CHECK: True

    // Idempotence: x AND x = x (with x = false)
    %idem2 = eco.bool.and %false, %false : i1
    %boxed9 = eco.box %idem2 : i1 -> !eco.value
    eco.dbg %boxed9 : !eco.value
    // CHECK: False

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
