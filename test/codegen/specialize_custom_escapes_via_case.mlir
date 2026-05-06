// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 negative: per Q4, a Custom value flowing into eco.case as the
// scrutinee counts as escaping. We do NOT widen eco.case to accept
// aggregate scrutinees in this work, so the heap allocation must be
// preserved.

module {
  func.func @custom_into_case(%inner: !eco.value) -> i64 {
    %c = eco.construct.custom(%inner) {tag = 1 : i64, size = 1 : i64, unboxed_bitmap = 0 : i64, constructor = "Just"}
       : (!eco.value) -> !eco.value
    %tag0 = arith.constant 0 : i64
    %tag1 = arith.constant 1 : i64
    %r = eco.case %c : !eco.value [0, 1] -> (i64) {case_kind = "ctor"} {
      eco.yield %tag0 : i64
    }, {
      eco.yield %tag1 : i64
    }
    return %r : i64
  }
}

// CHECK: llvm.func @custom_into_case
// CHECK: llvm.call @eco_alloc_custom
//
// CHECK-NOT: llvm.struct<(ptr<1>)>
