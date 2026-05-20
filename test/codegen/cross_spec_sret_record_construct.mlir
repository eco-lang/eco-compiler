// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 3 (Fix A) + Chunk 4 (lifted gate): an Elm-shape
// function (terminated by `eco.return`) whose result is a record with
// `!eco.value` element(s). Pre-fix the all-primitive gate punted these
// to the Boxed ABI; after lifting the gate, cross-spec routes the
// result through Sret and the wrapper re-boxes via a single
// `eco.construct.record` op (no intermediate `eco.make.record +
// eco.to_heap`).

module {
  func.func @rec_with_box(%x: !eco.value, %y: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["value", "value"],
          eco.logical_result_types = ["record:2:v:v"]
      } {
    %r = eco.construct.record(%x, %y) {field_count = 2, unboxed_bitmap = 0}
        : (!eco.value, !eco.value) -> !eco.value
    eco.return %r : !eco.value
  }
}

// Worker exists with a leading `!llvm.ptr` outparam (the sret slot)
// and a void return — never a multi-result with ptr<1> fields.
// CHECK: llvm.func @rec_with_box$unboxed
// CHECK-SAME: !llvm.ptr
//
// Wrapper exists with the original boxed ABI.
// CHECK: llvm.func @rec_with_box(
//
// Wrapper allocates the sret slot.
// CHECK: llvm.alloca
//
// The wrapper boxes via the runtime allocator — Fix A routes through
// `eco.construct.record`, which lowers to eco_alloc_record + store
// loop.
// CHECK: llvm.call @eco_alloc_record
