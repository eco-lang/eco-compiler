// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test two safepoints in a single basic block. The second safepoint's
// live roots should reference the first safepoint's relocated values.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @llvm.experimental.gc.relocate
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @llvm.experimental.gc.relocate

module {
  func.func @test_two_safepoints() -> i64 {
    %a = eco.constant Nil : !eco.value

    // First safepoint
    eco.safepoint %a : !eco.value

    // Second safepoint — should use relocated %a from first
    eco.safepoint %a : !eco.value

    // Use after both safepoints
    eco.dbg %a : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
