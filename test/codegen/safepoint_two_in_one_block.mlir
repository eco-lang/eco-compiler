// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that RS4GC wraps multiple non-leaf calls in a single basic
// block, each getting its own gc.statepoint. The second statepoint
// uses the relocated value from the first.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @llvm.experimental.gc.statepoint.p0

module {
  func.func @test_two_safepoints(%a: !eco.value) -> !eco.value {
    // RS4GC wraps each call in its own gc.statepoint without any MLIR-level
    // safepoint marker.
    %r1 = "eco.call"(%a) <{_operand_types = [!eco.value], callee = @foo}> : (!eco.value) -> !eco.value

    %r2 = "eco.call"(%r1) <{_operand_types = [!eco.value], callee = @foo}> : (!eco.value) -> !eco.value

    "eco.return"(%r2) {_operand_types = [!eco.value]} : (!eco.value) -> ()
  }
  func.func private @foo(!eco.value) -> !eco.value
}
