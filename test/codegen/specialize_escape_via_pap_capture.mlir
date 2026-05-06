// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1 escape rule: capturing the construct's result in an
// `eco.papCreate` slot counts as escaping. The conservative classifier
// rejects any use that isn't `eco.project.tuple2/3`, so the heap
// allocation must be preserved even with -enable-unboxed-agg on.

module {
  func.func private @worker(%clo: !eco.value, %x: !eco.value) -> !eco.value {
    return %x : !eco.value
  }

  func.func @escapes_via_pap_capture(%a: i64, %b: i64) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %clo = "eco.papCreate"(%t) {
      function = @worker,
      arity = 2 : i64,
      num_captured = 1 : i64,
      unboxed_bitmap = 0 : i64
    } : (!eco.value) -> !eco.value
    return %clo : !eco.value
  }
}

// CHECK: llvm.func @escapes_via_pap_capture
// CHECK: llvm.call @eco_alloc_tuple2
//
// CHECK-NOT: llvm.struct<(i64, i64)>
