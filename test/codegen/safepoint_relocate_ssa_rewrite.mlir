// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that gc.statepoint wraps the actual call and gc.relocate is
// emitted for values that have post-statepoint uses.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @foo
// CHECK: "gc-live"
// CHECK: @llvm.experimental.gc.result
// CHECK: @llvm.experimental.gc.relocate

module {
  func.func @test_two_roots(%a: !eco.value, %b: !eco.value) -> !eco.value {
    // Safepoint with two live roots — wraps the call to @foo
    eco.safepoint %a, %b : !eco.value, !eco.value

    %r = "eco.call"(%a) <{_operand_types = [!eco.value], callee = @foo}> : (!eco.value) -> !eco.value

    // Use %b after the safepoint — should be relocated
    "eco.return"(%b) {_operand_types = [!eco.value]} : (!eco.value) -> ()
  }
  func.func private @foo(!eco.value) -> !eco.value
}
