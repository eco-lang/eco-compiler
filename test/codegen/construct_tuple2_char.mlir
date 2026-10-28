// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct.tuple2 with i32 (Char) field.
// Regression: lowering didn't widen i32 to i64 for runtime call.

module {
  func.func @main() -> i64 {
    %a = arith.constant 42 : i64
    %b = arith.constant 65 : i32

    %tuple = eco.construct.tuple2 %a, %b {unboxed_bitmap = 13} : i64, i32 -> !eco.value

    %fb = eco.project.tuple2 %tuple[1] : !eco.value -> i32
    %fb_wide = arith.extui %fb : i32 to i64
    eco.dbg %fb_wide : i64
    // CHECK: 65

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
