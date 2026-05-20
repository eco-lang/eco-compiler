// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Wrapper-fca-fix Chunk 3 (Fix A) + Chunk 4 (lifted gate): an Elm-shape
// function (terminated by `eco.return`) returning a mixed-element
// Tuple2 (`(Int, value)`). Pre-fix the all-primitive gate rejected
// this on the `eco.return` side because the result aggregate carries
// a `!eco.value`; after lifting the gate, cross-spec promotes the
// result through Sret and the wrapper re-boxes via a single
// `eco.construct.tuple2` op.

module {
  func.func @pair_int_box(%n: i64, %b: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "value"],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %t = eco.construct.tuple2 %n, %b : i64, !eco.value -> !eco.value
    eco.return %t : !eco.value
  }
}

// Worker has the sret outparam and no multi-result with ptr<1>.
// CHECK: llvm.func @pair_int_box$unboxed
// CHECK-SAME: !llvm.ptr
//
// Wrapper preserves the original boxed ABI.
// CHECK: llvm.func @pair_int_box(
//
// Wrapper allocates the sret slot.
// CHECK: llvm.alloca
//
// The wrapper's re-box uses the alloc-uninit + per-field store helpers
// (Fix C lowering of the Tuple2 construct op).
// CHECK: llvm.call @eco_alloc_tuple2_uninit
// CHECK: llvm.call @eco_store_tuple_field
