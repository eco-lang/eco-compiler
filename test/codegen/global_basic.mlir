// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.global, eco.store_global, eco.load_global.

module {
  // Declare a global variable
  eco.global @my_counter

  func.func @main() -> i64 {
    // Store a value to the global
    %i42 = arith.constant 42 : i64
    %boxed = eco.box %i42 : i64 -> !eco.value
    eco.store_global %boxed, @my_counter

    // Load it back
    %loaded = eco.load_global @my_counter
    %unboxed = eco.unbox %loaded : !eco.value -> i64
    eco.dbg %unboxed : i64
    // CHECK: 42

    // Store a different value
    %i99 = arith.constant 99 : i64
    %boxed2 = eco.box %i99 : i64 -> !eco.value
    eco.store_global %boxed2, @my_counter

    // Load and verify
    %loaded2 = eco.load_global @my_counter
    %unboxed2 = eco.unbox %loaded2 : !eco.value -> i64
    eco.dbg %unboxed2 : i64
    // CHECK: 99

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
