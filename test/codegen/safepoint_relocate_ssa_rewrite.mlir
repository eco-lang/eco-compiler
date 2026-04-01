// RUN: %ecoc %s -emit=llvm 2>&1 | %FileCheck %s
//
// Test that gc.relocate is emitted after statepoints and that
// post-safepoint uses reference relocated values, not originals.
//
// Two live roots with uses after the safepoint should both get
// gc.relocate calls and their subsequent uses should be rewritten.
//
// CHECK: @llvm.experimental.gc.statepoint.p0
// CHECK: @llvm.experimental.gc.relocate
// CHECK: @llvm.experimental.gc.relocate
// CHECK: ptrtoint
// CHECK: ptrtoint

module {
  func.func @test_two_roots() -> i64 {
    %a = eco.constant Nil : !eco.value
    %b = eco.constant True : !eco.value

    // Safepoint with two live roots
    eco.safepoint %a, %b : !eco.value, !eco.value

    // Uses after safepoint should reference relocated values
    eco.dbg %a : !eco.value
    eco.dbg %b : !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
