// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.3: a function returning a tuple containing an `!eco.value`
// element. Cross-spec promotes the result via the sret ABI — the
// worker drops the aggregate from its return list and takes a leading
// `!llvm.ptr` outparam; the wrapper allocates a slot of the matching
// LLVM struct type, calls the worker with the slot pointer first, and
// rebuilds the aggregate from per-field loads before re-boxing via
// `eco.to_heap`.
//
// The slot's struct type has an `!eco.value` element mapped to
// `ptr addrspace(1)`, so the leading sret outparam is plain `!llvm.ptr`
// (addrspace 0) and the slot's body is `<i64, ptr addrspace(1)>`. No
// struct value containing `ptr addrspace(1)` crosses the call boundary —
// RS4GC's FCA-unimplemented assertion is structurally avoided.

module {
  func.func @pair_with_box(%n: i64, %b: !eco.value) -> !eco.value
      attributes {
          eco.logical_param_types = ["i64", "value"],
          eco.logical_result_types = ["tuple2:i:v"]
      } {
    %t = eco.construct.tuple2 %n, %b : i64, !eco.value -> !eco.value
    return %t : !eco.value
  }
}

// Worker exists with a leading `!llvm.ptr` outparam (the sret slot)
// and a void-equivalent (empty) return list:
// CHECK: llvm.func @pair_with_box$unboxed
// CHECK-SAME: !llvm.ptr
// CHECK-SAME: i64
// CHECK-SAME: ptr addrspace(1)
//
// Wrapper exists with the original boxed ABI:
// CHECK: llvm.func @pair_with_box(
//
// Wrapper allocates the sret slot:
// CHECK: llvm.alloca
//
// Wrapper boxes the rebuilt aggregate via the runtime allocator:
// CHECK: llvm.call @eco_alloc_tuple2
