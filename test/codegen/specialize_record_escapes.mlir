// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 negative: a Record whose result is returned by the enclosing
// function counts as escaping under the conservative classifier. Heap
// allocation must be preserved.

module {
  func.func @returns_record(%x: i64, %y: !eco.value) -> !eco.value {
    %r = eco.construct.record(%x, %y) {field_count = 2 : i64, unboxed_bitmap = 0 : i64}
       : (i64, !eco.value) -> !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @returns_record
// CHECK: llvm.call @eco_alloc_record
//
// CHECK-NOT: llvm.struct<(i64, ptr<1>)>
