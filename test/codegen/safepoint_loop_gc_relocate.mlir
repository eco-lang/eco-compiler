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
    // Both roots live across the first GC-triggering call; RS4GC sees this
    // automatically via ptr addrspace(1) liveness, no MLIR safepoint marker
    // needed.
    %r1 = "eco.call"(%root) <{_operand_types = [!eco.value], callee = @alloc_thing}> : (!eco.value) -> !eco.value

    // Second call: root and r1 live - root should use the relocated value
    // from the first call's statepoint.
    %r2 = "eco.call"(%r1) <{_operand_types = [!eco.value], callee = @alloc_thing}> : (!eco.value) -> !eco.value

    // Return root - should be the doubly-relocated value
    "eco.return"(%root) {_operand_types = [!eco.value]} : (!eco.value) -> ()
  }
  func.func private @alloc_thing(!eco.value) -> !eco.value
}
