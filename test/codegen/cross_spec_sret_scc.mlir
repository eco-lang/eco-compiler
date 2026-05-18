// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.3 × Phase 3.2 #1: a two-member SCC where both functions
// return a tuple containing an `!eco.value` element. The Sret ABI
// must compose with the SCC fixpoint — neither member is reachable
// outside the cycle so the SCC pass is the only way they become
// eligible at all.
//
// Both members get $unboxed workers with leading sret slots. Each
// intra-SCC call allocates its own local slot, then reads back the
// aggregate after the call — no heap round-trip between iterations.

module {
  // The bodies are pure-passthrough cross-SCC calls: this is a
  // codegen-only fixture (the cycle never terminates at runtime),
  // crafted to exercise the result-producer use check's same-SCC
  // call-result-passthrough branch — which is the only producer
  // form the eligibility analysis accepts at a `func.return` for a
  // promoted aggregate result. Conditional join shapes (`arith.select`,
  // `scf.if`) are not yet admitted; widening that producer set is
  // separate scope from Phase 3.3.
  func.func @even(%n: i64, %b: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "value"],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %rec = func.call @odd(%nm1, %b) : (i64, !eco.value) -> !eco.value
    return %rec : !eco.value
  }

  func.func @odd(%n: i64, %b: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "value"],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %rec = func.call @even(%nm1, %b) : (i64, !eco.value) -> !eco.value
    return %rec : !eco.value
  }
}

// Both SCC members get $unboxed workers (atomic promotion):
// CHECK-DAG: llvm.func @even$unboxed
// CHECK-DAG: llvm.func @odd$unboxed
//
// Intra-SCC calls hit the worker variants — no boxing round-trip:
// CHECK-DAG: llvm.call @odd$unboxed
// CHECK-DAG: llvm.call @even$unboxed
//
// Wrappers preserve the original boxed ABI:
// CHECK-DAG: llvm.func @even(
// CHECK-DAG: llvm.func @odd(
