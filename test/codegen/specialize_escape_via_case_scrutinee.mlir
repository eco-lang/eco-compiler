// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1 escape rule: using the construct's result as an eco.case
// scrutinee counts as escaping. eco.case is not eco.project.tuple2/3,
// so the conservative classifier rejects it and the heap allocation
// is preserved even with -enable-unboxed-agg on.
//
// case_kind="ctor" matches on a heap object's constructor tag via
// eco.get_tag; that path doesn't make sense for a Tuple2 in real Elm
// code, but exercising the classifier rule doesn't depend on the
// runtime semantics — only on the IR-level fact that the construct's
// result flows into an eco.case scrutinee position.

module {
  func.func @escapes_via_case_scrutinee(%a: i64, %b: i64) -> i64 {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %r = eco.case %t : !eco.value [0, 1] -> (i64) {case_kind = "ctor"} {
      eco.yield %a : i64
    }, {
      eco.yield %b : i64
    }
    return %r : i64
  }
}

// CHECK: llvm.func @escapes_via_case_scrutinee
// CHECK: llvm.call @eco_alloc_tuple2
//
// CHECK-NOT: llvm.struct<(i64, i64)>
