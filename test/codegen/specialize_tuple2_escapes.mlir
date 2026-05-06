// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1: a Tuple2 whose result is returned by the enclosing function
// counts as escaping under the conservative classifier — return is not
// a known projection. The construct op is left intact and lowers to the
// existing eco_alloc_tuple2 heap allocation path even with
// -enable-unboxed-agg on.

module {
  func.func @returns_tuple(%a: !eco.value, %b: !eco.value) -> !eco.value {
    %t = eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value
    return %t : !eco.value
  }
}

// CHECK: llvm.func @returns_tuple
// CHECK: llvm.call @eco_alloc_tuple2
//
// No value-aggregate machinery should appear for this function.
// CHECK-NOT: llvm.struct<(ptr<1>, ptr<1>)>
