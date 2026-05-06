// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1 escape rule: storing the construct's result into an
// `eco.store_global` operand counts as escaping. The conservative
// classifier rejects any use that isn't `eco.project.tuple2/3`, so the
// heap allocation must be preserved even with -enable-unboxed-agg on.

module {
  eco.global @g
  func.func @escapes_via_store_global(%a: i64, %b: i64) {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    eco.store_global %t, @g
    return
  }
}

// CHECK: llvm.func @escapes_via_store_global
// CHECK: llvm.call @eco_alloc_tuple2
//
// CHECK-NOT: llvm.struct<(i64, i64)>
