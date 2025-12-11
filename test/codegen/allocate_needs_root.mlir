// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate with needs_root=true attribute.
// This tests GC root registration during allocation.

module {
  func.func @main() -> i64 {
    // Allocate with needs_root=true
    %size1 = arith.constant 24 : i64
    %obj1 = eco.allocate %size1 {type = @TestType, needs_root = true} : i64 -> !eco.value
    eco.dbg %obj1 : !eco.value
    // CHECK: Ctor

    // Allocate with needs_root=false for comparison
    %size2 = arith.constant 32 : i64
    %obj2 = eco.allocate %size2 {type = @TestType2, needs_root = false} : i64 -> !eco.value
    eco.dbg %obj2 : !eco.value
    // CHECK: Ctor

    // Multiple allocations with needs_root=true
    %size3 = arith.constant 16 : i64
    %obj3 = eco.allocate %size3 {type = @TestType3, needs_root = true} : i64 -> !eco.value
    eco.dbg %obj3 : !eco.value
    // CHECK: Ctor

    %obj4 = eco.allocate %size3 {type = @TestType4, needs_root = true} : i64 -> !eco.value
    eco.dbg %obj4 : !eco.value
    // CHECK: Ctor

    // Larger allocation with needs_root
    %size5 = arith.constant 64 : i64
    %obj5 = eco.allocate %size5 {type = @LargeType, needs_root = true} : i64 -> !eco.value
    eco.dbg %obj5 : !eco.value
    // CHECK: Ctor

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
