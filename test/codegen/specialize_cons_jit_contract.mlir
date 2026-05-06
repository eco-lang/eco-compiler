// RUN: %ecoc %s -emit=jit -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 end-to-end contract: a non-escaping cons cell rewritten to
// eco.make.cons must produce the same projected head/tail values as
// the heap path would. The no-allocation half is asserted by
// specialize_cons_local.mlir.

module {
  func.func @main() -> i64 {
    %h = arith.constant 7 : i64
    %hv = eco.box %h : i64 -> !eco.value
    %nil = eco.constant Nil : !eco.value
    %c = eco.construct.list %hv, %nil : !eco.value, !eco.value -> !eco.value
    %head = eco.project.list_head %c : !eco.value -> !eco.value
    %i = eco.unbox %head : !eco.value -> i64
    eco.dbg %i : i64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: 7
