// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.global with initializer function attribute.
// Note: The initializer attribute is optional and may not trigger
// automatic initialization in all cases.

module {
  // Simple global without initializer
  eco.global @simple_global

  // We can't test the = @init_func syntax without actual initialization
  // infrastructure, so test basic global functionality extensively
  eco.global @g1
  eco.global @g2

  func.func @main() -> i64 {
    // Store values in globals
    %i42 = arith.constant 42 : i64
    %i100 = arith.constant 100 : i64
    %b42 = eco.box %i42 : i64 -> !eco.value
    %b100 = eco.box %i100 : i64 -> !eco.value

    eco.store_global %b42, @simple_global
    eco.store_global %b100, @g1

    // Load and verify
    %v1 = eco.load_global @simple_global
    eco.dbg %v1 : !eco.value
    // CHECK: 42

    %v2 = eco.load_global @g1
    eco.dbg %v2 : !eco.value
    // CHECK: 100

    // Store a constructed value
    %nil = eco.constant Nil : !eco.value
    %list = eco.construct(%b42, %nil) {tag = 0 : i64, size = 2 : i64} : (!eco.value, !eco.value) -> !eco.value
    eco.store_global %list, @g2

    %v3 = eco.load_global @g2
    eco.dbg %v3 : !eco.value
    // CHECK: [42]

    // Update a global multiple times
    %i1 = arith.constant 1 : i64
    %i2 = arith.constant 2 : i64
    %i3 = arith.constant 3 : i64
    %b1 = eco.box %i1 : i64 -> !eco.value
    %b2 = eco.box %i2 : i64 -> !eco.value
    %b3 = eco.box %i3 : i64 -> !eco.value

    eco.store_global %b1, @simple_global
    %r1 = eco.load_global @simple_global
    eco.dbg %r1 : !eco.value
    // CHECK: 1

    eco.store_global %b2, @simple_global
    %r2 = eco.load_global @simple_global
    eco.dbg %r2 : !eco.value
    // CHECK: 2

    eco.store_global %b3, @simple_global
    %r3 = eco.load_global @simple_global
    eco.dbg %r3 : !eco.value
    // CHECK: 3

    // Store constants
    %unit = eco.constant Unit : !eco.value
    eco.store_global %unit, @g1
    %v_unit = eco.load_global @g1
    eco.dbg %v_unit : !eco.value
    // CHECK: ()

    %true_const = eco.constant True : !eco.value
    eco.store_global %true_const, @g2
    %v_true = eco.load_global @g2
    eco.dbg %v_true : !eco.value
    // CHECK: True

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
