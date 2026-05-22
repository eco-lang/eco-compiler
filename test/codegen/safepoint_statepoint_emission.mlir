// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that functions get gc "eco-gc" attribute and that RS4GC
// inserts gc.statepoint intrinsics around non-leaf calls.
//
// CHECK: gc "eco-gc"
// CHECK: @llvm.experimental.gc.statepoint.p0

module {
  func.func @main() -> i64 {
    // Use a heap-allocated value as GC root (not an embedded constant).
    // Embedded constants (Nil, True, etc.) are excluded from GC roots
    // because they are not heap objects and never need relocation.
    %i42 = arith.constant 42 : i64
    %boxed = eco.box %i42 : i64 -> !eco.value

    // eco.box lowers to a call to eco_alloc_int; RS4GC wraps that call
    // in gc.statepoint automatically. No MLIR-level safepoint marker
    // is required.

    eco.dbg %boxed : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
