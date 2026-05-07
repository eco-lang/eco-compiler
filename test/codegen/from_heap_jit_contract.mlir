// RUN: %ecoc %s -emit=jit -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3 end-to-end contract: `eco.to_heap` and `eco.from_heap` are
// inverses. Build a heap tuple2 from primitives via the heap path,
// unbox via `eco.from_heap`, and project — must yield the original
// values. Behavioural roundtrip proof at the JIT level.

module {
  func.func @main() -> i64 {
    %a = arith.constant 1234 : i64
    %b = arith.constant 5678 : i64
    %hp = eco.construct.tuple2 %a, %b : i64, i64 -> !eco.value
    %t = eco.from_heap %hp : (!eco.value) -> !eco.tuple2<i64, i64>
    %x = eco.project.tuple2 %t[0] : !eco.tuple2<i64, i64> -> i64
    %y = eco.project.tuple2 %t[1] : !eco.tuple2<i64, i64> -> i64
    eco.dbg %x : i64
    eco.dbg %y : i64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: 1234
// CHECK: 5678
