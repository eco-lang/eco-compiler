// RUN: %ecoc %s -emit=jit -enable-unboxed-agg 2>&1 | %FileCheck %s
//
// Phase 3 Step 5: JIT-level behavioural contract for cross-function
// specialisation. A function `add_pair : (Int, Int) -> Int` with
// `tuple2:i:i` logical param shape is split into wrapper/worker; the
// wrapper takes `!eco.value`, unboxes via `eco.from_heap`, calls the
// worker which projects from the aggregate struct. Calling `add_pair`
// from `main` with a heap-allocated tuple must yield the correct sum.

module {
  func.func @add_pair(%p: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %a = eco.project.tuple2 %p[0] : !eco.value -> i64
    %b = eco.project.tuple2 %p[1] : !eco.value -> i64
    %s = arith.addi %a, %b : i64
    return %s : i64
  }

  func.func @main() -> i64 {
    %x = arith.constant 100 : i64
    %y = arith.constant 23 : i64
    %t = eco.construct.tuple2 %x, %y : i64, i64 -> !eco.value
    %r = func.call @add_pair(%t) : (!eco.value) -> i64
    eco.dbg %r : i64
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK: 123
