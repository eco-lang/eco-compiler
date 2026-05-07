// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3: eco.from_heap unboxes a heap tuple2 into a value-aggregate
// !eco.tuple2<i64, i64>. Lowering must resolve the HPointer once and
// then load each field at the Tuple2 layout offsets, packing the
// loaded values into an LLVM struct via insertvalue.

module {
  func.func @from_heap_tuple2(%hp: !eco.value) -> i64 {
    %t = eco.from_heap %hp : (!eco.value) -> !eco.tuple2<i64, i64>
    %a = eco.project.tuple2 %t[0] : !eco.tuple2<i64, i64> -> i64
    %b = eco.project.tuple2 %t[1] : !eco.tuple2<i64, i64> -> i64
    %s = arith.addi %a, %b : i64
    return %s : i64
  }
}

// CHECK: llvm.func @from_heap_tuple2
// CHECK: llvm.call @eco_resolve_hptr
// CHECK: llvm.mlir.undef : !llvm.struct<(i64, i64)>
// CHECK: llvm.insertvalue
// CHECK: llvm.extractvalue
//
// CHECK-NOT: llvm.call @eco_alloc_tuple2
