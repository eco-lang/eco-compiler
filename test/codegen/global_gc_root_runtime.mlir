// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Runtime test verifying eco.global registers GC roots correctly.
// This test calls eco_gc_jit_root_count() to verify roots are registered.

module {
  // Declare three globals - should result in 3 JIT roots
  eco.global @global_x
  eco.global @global_y
  eco.global @global_z

  // External function to query JIT root count
  llvm.func @eco_gc_jit_root_count() -> i64

  func.func @main() -> i64 {
    // Query the number of registered JIT roots
    %root_count = llvm.call @eco_gc_jit_root_count() : () -> i64

    // Print it - should be 3
    eco.dbg %root_count : i64
    // CHECK: 3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
