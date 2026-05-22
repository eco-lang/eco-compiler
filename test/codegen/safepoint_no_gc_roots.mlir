// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test: Function with no GC-triggering calls produces no statepoint
// intrinsics (RS4GC inserts statepoints only at calls).
//
// CHECK: define i64 @no_safepoint
// CHECK-NOT: @llvm.experimental.gc.statepoint

module {
  func.func @no_safepoint(%x: i64) -> i64 {
    %c1 = arith.constant 1 : i64
    %r = arith.addi %x, %c1 : i64
    return %r : i64
  }
}
