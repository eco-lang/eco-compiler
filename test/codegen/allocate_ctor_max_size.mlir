// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_ctor with larger sizes.
// Tests that allocation works correctly for larger structures.

module {
  func.func @main() -> i64 {
    // Allocate ctor with 10 fields
    %ctor10 = eco.allocate_ctor {tag = 5 : i64, size = 10 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor10 : !eco.value
    // CHECK: Ctor5

    // Allocate ctor with 20 fields
    %ctor20 = eco.allocate_ctor {tag = 7 : i64, size = 20 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor20 : !eco.value
    // CHECK: Ctor7

    // Allocate ctor with 50 fields (stress test)
    %ctor50 = eco.allocate_ctor {tag = 0 : i64, size = 50 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor50 : !eco.value
    // CHECK: Ctor0

    // Verify we can still allocate normal sized ctors after
    // Note: tag=1 with size=2 would be confused with list cons cells in printing,
    // so we use tag=2 to avoid this ambiguity
    %ctor2 = eco.allocate_ctor {tag = 2 : i64, size = 2 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor2 : !eco.value
    // CHECK: Ctor2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
