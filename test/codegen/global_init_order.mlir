// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test multiple globals with initialization order.
// Verifies globals are initialized in declaration order.

module {
  // Declare globals
  eco.global @g1
  eco.global @g2
  eco.global @g3

  func.func @main() -> i64 {
    // Initialize in specific order
    %c1 = arith.constant 100 : i64
    %b1 = eco.box %c1 : i64 -> !eco.value
    eco.store_global %b1, @g1

    // g2 depends on g1 (in real code, this might be computed)
    %c2 = arith.constant 200 : i64
    %b2 = eco.box %c2 : i64 -> !eco.value
    eco.store_global %b2, @g2

    // g3 stores a reference (indirect dependency)
    %c3 = arith.constant 300 : i64
    %b3 = eco.box %c3 : i64 -> !eco.value
    eco.store_global %b3, @g3

    // Load all and verify values
    %l1 = eco.load_global @g1
    %l2 = eco.load_global @g2
    %l3 = eco.load_global @g3

    %v1 = eco.unbox %l1 : !eco.value -> i64
    %v2 = eco.unbox %l2 : !eco.value -> i64
    %v3 = eco.unbox %l3 : !eco.value -> i64

    eco.dbg %v1 : i64
    // CHECK: 100

    eco.dbg %v2 : i64
    // CHECK: 200

    eco.dbg %v3 : i64
    // CHECK: 300

    // Compute sum to verify all loaded correctly
    %s12 = eco.int.add %v1, %v2 : i64
    %sum = eco.int.add %s12, %v3 : i64
    eco.dbg %sum : i64
    // CHECK: 600

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
