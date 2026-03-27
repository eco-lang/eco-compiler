// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.construct.tuple2 with i16 (Char) field.
// Regression: lowering didn't widen i16 to i64 for runtime call.

module {
  func.func @main() -> i64 {
    %a = arith.constant 42 : i64
    %b = arith.constant 65 : i16

    %tuple = eco.construct.tuple2 %a, %b {unboxed_bitmap = 3} : i64, i16 -> !eco.value

    %fb = eco.project.tuple2 %tuple[1] : !eco.value -> i16
    %fb_wide = arith.extui %fb : i16 to i64
    eco.dbg %fb_wide : i64
    // CHECK: 65

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
