// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test overwriting a global multiple times.
// Verifies that each store replaces the previous value.

module {
  eco.global @value

  func.func @main() -> i64 {
    // First store
    %c10 = arith.constant 10 : i64
    %b10 = eco.box %c10 : i64 -> !eco.value
    eco.store_global %b10, @value

    %l1 = eco.load_global @value
    %v1 = eco.unbox %l1 : !eco.value -> i64
    eco.dbg %v1 : i64
    // CHECK: 10

    // Overwrite with different value
    %c20 = arith.constant 20 : i64
    %b20 = eco.box %c20 : i64 -> !eco.value
    eco.store_global %b20, @value

    %l2 = eco.load_global @value
    %v2 = eco.unbox %l2 : !eco.value -> i64
    eco.dbg %v2 : i64
    // CHECK: 20

    // Overwrite with different type (store a constructed value)
    %inner = eco.box %c10 : i64 -> !eco.value
    %ctor = eco.construct(%inner) {tag = 1 : i64, size = 1 : i64} : (!eco.value) -> !eco.value
    eco.store_global %ctor, @value

    %l3 = eco.load_global @value
    eco.dbg %l3 : !eco.value
    // CHECK: Ctor1

    // Overwrite back to simple value
    %c30 = arith.constant 30 : i64
    %b30 = eco.box %c30 : i64 -> !eco.value
    eco.store_global %b30, @value

    %l4 = eco.load_global @value
    %v4 = eco.unbox %l4 : !eco.value -> i64
    eco.dbg %v4 : i64
    // CHECK: 30

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
