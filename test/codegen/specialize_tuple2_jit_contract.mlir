// RUN: %ecoc %s -emit=jit -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 1 end-to-end contract: a non-escaping all-primitive Tuple2
// rewritten to eco.make.tuple2 must produce the same projected values
// it would have produced via the heap path. This is the behavioural
// half of the "no allocation, same behaviour" contract — the
// no-allocation half is asserted by specialize_tuple2_local.mlir.
//
// JIT-executes the program; the eco.dbg lines flush the projected i64
// values, and the CHECK lines below assert that field-0 prints first
// and field-1 second.

module {
  func.func @main() -> i64 {
    %a = arith.constant 42 : i64
    %b = arith.constant 99 : i64
    %t = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %x = eco.project.tuple2 %t[0] : !eco.value -> i64
    %y = eco.project.tuple2 %t[1] : !eco.value -> i64
    eco.dbg %x : i64
    eco.dbg %y : i64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: 42
// CHECK: 99
