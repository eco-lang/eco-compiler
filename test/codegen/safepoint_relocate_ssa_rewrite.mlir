// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that RS4GC wraps non-leaf calls in gc.statepoint and emits
// gc.relocate for live ptr addrspace(1) values across the call.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: "gc-live"
// CHECK: @llvm.experimental.gc.relocate

module {
  func.func @test_two_roots(%a: !eco.value, %b: !eco.value) -> !eco.value {
    // eco.safepoint is a no-op under RS4GC — roots are tracked
    // automatically by ptr addrspace(1) type.
    eco.safepoint %a, %b : !eco.value, !eco.value

    %r = "eco.call"(%a) <{_operand_types = [!eco.value], callee = @foo}> : (!eco.value) -> !eco.value

    // Use %b after the call — RS4GC should relocate it
    "eco.return"(%b) {_operand_types = [!eco.value]} : (!eco.value) -> ()
  }
  func.func private @foo(!eco.value) -> !eco.value
}
