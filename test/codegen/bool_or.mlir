// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.bool.or operation - truth table and properties.

module {
  func.func @main() -> i64 {
    %true = arith.constant true
    %false = arith.constant false

    // Truth table: T OR T = T
    %tt = eco.bool.or %true, %true : i1
    %boxed1 = eco.box %tt : i1 -> !eco.value
    eco.dbg %boxed1 : !eco.value
    // CHECK: True

    // Truth table: T OR F = T
    %tf = eco.bool.or %true, %false : i1
    %boxed2 = eco.box %tf : i1 -> !eco.value
    eco.dbg %boxed2 : !eco.value
    // CHECK: True

    // Truth table: F OR T = T
    %ft = eco.bool.or %false, %true : i1
    %boxed3 = eco.box %ft : i1 -> !eco.value
    eco.dbg %boxed3 : !eco.value
    // CHECK: True

    // Truth table: F OR F = F
    %ff = eco.bool.or %false, %false : i1
    %boxed4 = eco.box %ff : i1 -> !eco.value
    eco.dbg %boxed4 : !eco.value
    // CHECK: False

    // Identity: x OR false = x (with x = true)
    %id1 = eco.bool.or %true, %false : i1
    %boxed5 = eco.box %id1 : i1 -> !eco.value
    eco.dbg %boxed5 : !eco.value
    // CHECK: True

    // Identity: x OR false = x (with x = false)
    %id2 = eco.bool.or %false, %false : i1
    %boxed6 = eco.box %id2 : i1 -> !eco.value
    eco.dbg %boxed6 : !eco.value
    // CHECK: False

    // Annihilator: x OR true = true (with x = false)
    %ann1 = eco.bool.or %false, %true : i1
    %boxed7 = eco.box %ann1 : i1 -> !eco.value
    eco.dbg %boxed7 : !eco.value
    // CHECK: True

    // Idempotence: x OR x = x (with x = true)
    %idem1 = eco.bool.or %true, %true : i1
    %boxed8 = eco.box %idem1 : i1 -> !eco.value
    eco.dbg %boxed8 : !eco.value
    // CHECK: True

    // Idempotence: x OR x = x (with x = false)
    %idem2 = eco.bool.or %false, %false : i1
    %boxed9 = eco.box %idem2 : i1 -> !eco.value
    eco.dbg %boxed9 : !eco.value
    // CHECK: False

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
