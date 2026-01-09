// XFAIL: eco_dbg_print crashes on null/uninitialized globals
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test reading a global before any write.
// Should return 0/null (the initial value).

module {
  // Declare globals (no type annotation needed)
  eco.global @uninit_global
  eco.global @another_uninit

  func.func @main() -> i64 {
    // Read global before any write - should be 0 (null pointer)
    %val1 = eco.load_global @uninit_global
    eco.dbg %val1 : !eco.value
    // CHECK: <null>

    // Read another uninitialized global
    %val2 = eco.load_global @another_uninit
    eco.dbg %val2 : !eco.value
    // CHECK: <null>

    // Now write to one
    %i42 = arith.constant 42 : i64
    %boxed = eco.box %i42 : i64 -> !eco.value
    eco.store_global %boxed, @uninit_global

    // Read it back - should have the value
    %val3 = eco.load_global @uninit_global
    eco.dbg %val3 : !eco.value
    // CHECK: 42

    // The other one is still uninitialized
    %val4 = eco.load_global @another_uninit
    eco.dbg %val4 : !eco.value
    // CHECK: <null>

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
