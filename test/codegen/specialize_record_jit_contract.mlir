// RUN: %ecoc %s -emit=jit -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 2 end-to-end contract: a non-escaping mixed-kind record
// rewritten to eco.make.record must produce the same projected values
// as the heap path would. JIT-execute, dump the projections, assert
// the values via CHECK lines.

module {
  func.func @main() -> i64 {
    %a = arith.constant 42 : i64
    %b = arith.constant 7.0 : f64
    %r = eco.construct.record(%a, %b) {field_count = 2 : i64, unboxed_bitmap = 5 : i64}
       : (i64, f64) -> !eco.value
    %x = eco.project.record %r[0] : !eco.value -> i64
    %y = eco.project.record %r[1] : !eco.value -> f64
    eco.dbg %x : i64
    eco.dbg %y : f64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: 42
// CHECK: 7
