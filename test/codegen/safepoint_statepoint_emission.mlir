// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that eco.safepoint ops are lowered to gc.statepoint intrinsics
// with gc-live operand bundles, gc.relocate intrinsics, and GC strategy
// on functions.
//
// CHECK: gc "statepoint-example"
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: "gc-live"
// CHECK: @llvm.experimental.gc.relocate
// CHECK: ptrtoint

module {
  func.func @main() -> i64 {
    %nil = eco.constant Nil : !eco.value
    %true = eco.constant True : !eco.value

    // Safepoint with two live roots
    eco.safepoint %nil, %true : !eco.value, !eco.value

    eco.dbg %nil : !eco.value

    // Safepoint with one live root
    eco.safepoint %nil : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
