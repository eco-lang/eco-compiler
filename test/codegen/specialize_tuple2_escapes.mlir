// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1: an all-primitive Tuple2 whose result is returned by the
// enclosing function counts as escaping under the conservative
// classifier — return is not a known projection. The construct op is
// left intact and lowers via the existing eco_alloc_tuple2 heap path
// even with -enable-unboxed-agg on. (`returns_tuple` doesn't actually
// type-check in real Eco programs because !eco.value carrying a
// boxed Tuple2 would normally need GC-rooted operands; here we exploit
// the parse-time relaxation only to exercise the escape rule on a
// primitive-valued tuple.)

module {
  func.func @returns_tuple(%a: i64, %b: i64) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    return %t : !eco.value
  }
}

// CHECK: llvm.func @returns_tuple
// CHECK: llvm.call @__eco_alloc_inline
//
// No value-aggregate machinery should appear for this function.
// CHECK-NOT: llvm.struct<(i64, i64)>
