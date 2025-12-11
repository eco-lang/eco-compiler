// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_ctor with non-zero scalar_bytes attribute.
// scalar_bytes indicates bytes of scalar (non-pointer) data.

module {
  func.func @main() -> i64 {
    // Allocate with 0 scalar bytes (normal pointer fields)
    %ctor0 = eco.allocate_ctor {tag = 1 : i64, size = 2 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor0 : !eco.value
    // CHECK: Ctor1

    // Allocate with 8 scalar bytes (one i64 worth)
    %ctor8 = eco.allocate_ctor {tag = 2 : i64, size = 1 : i64, scalar_bytes = 8 : i64} : !eco.value
    eco.dbg %ctor8 : !eco.value
    // CHECK: Ctor2

    // Allocate with 16 scalar bytes (two i64 worth)
    %ctor16 = eco.allocate_ctor {tag = 3 : i64, size = 2 : i64, scalar_bytes = 16 : i64} : !eco.value
    eco.dbg %ctor16 : !eco.value
    // CHECK: Ctor3

    // Allocate with 24 scalar bytes (three i64 worth)
    %ctor24 = eco.allocate_ctor {tag = 4 : i64, size = 3 : i64, scalar_bytes = 24 : i64} : !eco.value
    eco.dbg %ctor24 : !eco.value
    // CHECK: Ctor4

    // Allocate with large size and some scalar bytes
    %ctor_mixed = eco.allocate_ctor {tag = 5 : i64, size = 5 : i64, scalar_bytes = 16 : i64} : !eco.value
    eco.dbg %ctor_mixed : !eco.value
    // CHECK: Ctor5

    // Zero-field ctor with zero scalar bytes
    %ctor_empty = eco.allocate_ctor {tag = 0 : i64, size = 0 : i64, scalar_bytes = 0 : i64} : !eco.value
    eco.dbg %ctor_empty : !eco.value
    // CHECK: Ctor0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
