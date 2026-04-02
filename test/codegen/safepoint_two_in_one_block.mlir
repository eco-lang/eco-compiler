// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test two safepoints in a single basic block. Each wraps its
// respective call. The second call uses the relocated value from
// the first statepoint.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @foo
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @foo

module {
  func.func @test_two_safepoints(%a: !eco.value) -> !eco.value {
    // First safepoint wraps first call to @foo
    eco.safepoint %a : !eco.value
    %r1 = "eco.call"(%a) <{_operand_types = [!eco.value], callee = @foo}> : (!eco.value) -> !eco.value

    // Second safepoint wraps second call to @foo
    eco.safepoint %a, %r1 : !eco.value, !eco.value
    %r2 = "eco.call"(%r1) <{_operand_types = [!eco.value], callee = @foo}> : (!eco.value) -> !eco.value

    "eco.return"(%r2) {_operand_types = [!eco.value]} : (!eco.value) -> ()
  }
  func.func private @foo(!eco.value) -> !eco.value
}
