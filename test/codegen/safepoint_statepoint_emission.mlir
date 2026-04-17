// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that eco.safepoint ops are lowered to gc.statepoint intrinsics
// that wrap __eco_safepoint_poll, with gc-live operand bundles and
// GC strategy on functions.
//
// CHECK: gc "statepoint-example"
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: __eco_safepoint_poll
// CHECK: "gc-live"

module {
  func.func @main() -> i64 {
    // Use a heap-allocated value as GC root (not an embedded constant).
    // Embedded constants (Nil, True, etc.) are excluded from GC roots
    // because they are not heap objects and never need relocation.
    %i42 = arith.constant 42 : i64
    %boxed = eco.box %i42 : i64 -> !eco.value

    // Safepoint with one live root — wraps the following eco.dbg call
    eco.safepoint %boxed : !eco.value

    eco.dbg %boxed : !eco.value

    // Safepoint with same root — no following call, so no statepoint emitted
    eco.safepoint %boxed : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
