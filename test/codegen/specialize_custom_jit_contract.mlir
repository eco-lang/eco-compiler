// RUN: %ecoc %s -emit=jit -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 end-to-end contract: a non-escaping Custom ADT
// rewritten to eco.make.custom must produce the same projected value
// it would have produced via the heap path. Behavioural half of the
// "no allocation, same behaviour" contract for Custom; the
// no-allocation half is asserted by specialize_custom_local.mlir.

module {
  func.func @main() -> i64 {
    %inner = arith.constant 314 : i64
    %iv = eco.box %inner : i64 -> !eco.value
    %c = eco.construct.custom(%iv) {tag = 1 : i64, size = 1 : i64, unboxed_bitmap = 0 : i64, constructor = "Just"}
       : (!eco.value) -> !eco.value
    %v = eco.project.custom %c[0] : !eco.value -> !eco.value
    %i = eco.unbox %v : !eco.value -> i64
    eco.dbg %i : i64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: 314
