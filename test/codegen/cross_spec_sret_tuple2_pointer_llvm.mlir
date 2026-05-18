// RUN: %ecoc %s -emit=llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3.3 LLVM-IR validation for the sret result path. After SROA +
// RS4GC, the worker should be void-returning with a leading `ptr` (the
// caller-allocated sret slot), an `i64`, and a `ptr addrspace(1)`. No
// struct value containing `ptr addrspace(1)` may appear on a call
// boundary — RS4GC would reject it. The wrapper retains the original
// boxed ABI and still issues an alloca for the slot (SROA cannot fold
// the alloca across the worker call, by design — that's the whole
// point of sret).

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

// Worker: void return, leading sret pointer, then the original
// (i64, ptr addrspace(1)) params. MLIR's LLVM lowering doesn't emit
// the `private` linkage marker for `sym_visibility = "private"`, so
// the signature opens with bare `define void`:
// CHECK: define void @"pair_with_box$unboxed"(ptr {{[^,]*}}, i64 {{[^,]*}}, ptr addrspace(1) {{[^)]*}})
//
// Worker body emits two stores (one per field) and returns void:
// CHECK: store i64
// CHECK: store ptr addrspace(1)
// CHECK: ret void
//
// Wrapper: original boxed ABI, allocates the sret slot before the call:
// CHECK: define ptr addrspace(1) @pair_with_box(i64 {{[^,]*}}, ptr addrspace(1) {{[^)]*}})
// CHECK: alloca
// CHECK: @"pair_with_box$unboxed"
// CHECK: @eco_alloc_tuple2
//
// CRITICAL safety check: nowhere in the IR may the worker return a
// struct containing `ptr addrspace(1)` — that is the exact FCA-with-
// gc-pointer return RS4GC asserts on, and the sret ABI exists to
// avoid it:
// CHECK-NOT: define {{.*}}{ {{.*}}ptr addrspace(1){{.*}} } @"pair_with_box$unboxed"
