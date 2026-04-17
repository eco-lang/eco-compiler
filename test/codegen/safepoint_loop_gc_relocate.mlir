// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that GC roots are correctly relocated across safepoints.
// The alloca/mem2reg approach emits gc.relocate for all live roots
// and produces correct SSA after promotion.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @llvm.experimental.gc.relocate
// CHECK-NOT: alloca

module {
  func.func @test_loop_root(%root: !eco.value, %other: !eco.value) -> !eco.value {
    // First safepoint: both roots live
    eco.safepoint %root, %other : !eco.value, !eco.value
    %r1 = "eco.call"(%root) <{_operand_types = [!eco.value], callee = @alloc_thing}> : (!eco.value) -> !eco.value

    // Second safepoint: root and r1 live - root should use relocated value from first
    eco.safepoint %root, %r1 : !eco.value, !eco.value
    %r2 = "eco.call"(%r1) <{_operand_types = [!eco.value], callee = @alloc_thing}> : (!eco.value) -> !eco.value

    // Return root - should be the doubly-relocated value
    "eco.return"(%root) {_operand_types = [!eco.value]} : (!eco.value) -> ()
  }
  func.func private @alloc_thing(!eco.value) -> !eco.value
}
