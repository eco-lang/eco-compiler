// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1 escape rule: passing the construct's result to an
// eco.call counts as escaping. Conservative classifier rejects anything
// that isn't an eco.project.tuple2 / tuple3 use, so the heap allocation
// is preserved even with -enable-unboxed-agg on.
//
// Uses primitive operands so the rewrite isn't blocked by the FCA-with-
// GC-pointer guard; the test focuses on the "escapes via call" rule
// alone.

module {
  func.func private @sink(!eco.value) -> !eco.value
  func.func @escapes_via_call(%a: i64, %b: i64) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %r = "eco.call"(%t) {callee = @sink} : (!eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @escapes_via_call
// CHECK: llvm.call @eco_alloc_tuple2
//
// CHECK-NOT: llvm.struct<(i64, i64)>
