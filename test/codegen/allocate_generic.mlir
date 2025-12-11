// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate (generic allocation) operation.
// This is the low-level allocation primitive.

module {
  func.func @main() -> i64 {
    // Allocate 24 bytes (header + 2 fields worth of space)
    %size1 = arith.constant 24 : i64
    %obj1 = eco.allocate %size1 {type = @Custom, needs_root = false} : i64 -> !eco.value
    eco.dbg %obj1 : !eco.value
    // CHECK: Ctor

    // Allocate 32 bytes
    %size2 = arith.constant 32 : i64
    %obj2 = eco.allocate %size2 {type = @Custom, needs_root = false} : i64 -> !eco.value
    eco.dbg %obj2 : !eco.value
    // CHECK: Ctor

    // Allocate minimum size (just header)
    %size3 = arith.constant 16 : i64
    %obj3 = eco.allocate %size3 {type = @Custom, needs_root = false} : i64 -> !eco.value
    eco.dbg %obj3 : !eco.value
    // CHECK: Ctor

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
