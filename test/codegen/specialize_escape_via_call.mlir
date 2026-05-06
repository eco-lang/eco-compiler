// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1 escape rule: passing the construct's result to an unknown
// eco.call counts as escaping. Conservative classifier rejects anything
// that isn't an eco.project.tuple2 / tuple3 use, so the heap allocation
// is preserved even with -enable-unboxed-agg on.

module {
  func.func private @sink(!eco.value) -> !eco.value
  func.func @escapes_via_call(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value
    %r = "eco.call"(%t) {callee = @sink} : (!eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @escapes_via_call
// CHECK: llvm.call @eco_alloc_tuple2
//
// CHECK-NOT: llvm.struct<(ptr<1>, ptr<1>)>
