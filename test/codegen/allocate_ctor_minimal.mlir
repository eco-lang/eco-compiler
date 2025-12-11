// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_ctor with minimal sizes.
// Tests zero fields and zero scalar_bytes.

module {
  func.func @main() -> i64 {
    // Allocate with 0 fields, 0 scalar_bytes (unit-like)
    %unit = eco.allocate_ctor {tag = 0 : i64, size = 0 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %unit : !eco.value
    // CHECK: Ctor0

    // Allocate with 0 fields but some scalar_bytes
    %scalar_only = eco.allocate_ctor {tag = 1 : i64, size = 0 : i64, scalar_bytes = 8 : i64} : !eco.value
    eco.dbg %scalar_only : !eco.value
    // CHECK: Ctor1

    // Allocate with 1 field, 0 scalar_bytes
    %one_field = eco.allocate_ctor {tag = 2 : i64, size = 1 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %one_field : !eco.value
    // CHECK: Ctor2

    // Different tags for same structure
    %tag_10 = eco.allocate_ctor {tag = 10 : i64, size = 0 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %tag_10 : !eco.value
    // CHECK: Ctor10

    %tag_100 = eco.allocate_ctor {tag = 100 : i64, size = 0 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %tag_100 : !eco.value
    // CHECK: Ctor100

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
