// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test repeated store/load cycles on a global.
// Verifies global state is properly maintained across operations.

module {
  eco.global @counter

  func.func @main() -> i64 {
    // Initial store
    %c0 = arith.constant 0 : i64
    %b0 = eco.box %c0 : i64 -> !eco.value
    eco.store_global %b0, @counter

    // Load, increment, store cycle 1
    %l1 = eco.load_global @counter
    %v1 = eco.unbox %l1 : !eco.value -> i64
    %one = arith.constant 1 : i64
    %v1_inc = eco.int.add %v1, %one : i64
    %b1 = eco.box %v1_inc : i64 -> !eco.value
    eco.store_global %b1, @counter

    eco.dbg %v1_inc : i64
    // CHECK: 1

    // Load, increment, store cycle 2
    %l2 = eco.load_global @counter
    %v2 = eco.unbox %l2 : !eco.value -> i64
    %v2_inc = eco.int.add %v2, %one : i64
    %b2 = eco.box %v2_inc : i64 -> !eco.value
    eco.store_global %b2, @counter

    eco.dbg %v2_inc : i64
    // CHECK: 2

    // Load, increment, store cycle 3
    %l3 = eco.load_global @counter
    %v3 = eco.unbox %l3 : !eco.value -> i64
    %v3_inc = eco.int.add %v3, %one : i64
    %b3 = eco.box %v3_inc : i64 -> !eco.value
    eco.store_global %b3, @counter

    eco.dbg %v3_inc : i64
    // CHECK: 3

    // Final load to verify
    %final = eco.load_global @counter
    %final_v = eco.unbox %final : !eco.value -> i64
    eco.dbg %final_v : i64
    // CHECK: 3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
