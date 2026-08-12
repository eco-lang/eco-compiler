// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// kernel-opt-12: `eco.cse_safe` is a discardable dialect attribute on
// eco.call (like eco.gc_roots_count) — it needs no ODS argument entry and
// must round-trip through the parser/printer unchanged. `callee` lives in the
// properties dict <{...}> and therefore precedes the discardable
// {eco.cse_safe} in the printed form.

module {
  func.func private @Elm_Kernel_String_length(%s: !eco.value) -> !eco.value

  func.func @main() -> i64 {
    %c = arith.constant 3 : i64
    %v = eco.box %c : i64 -> !eco.value
    %n = "eco.call"(%v) {callee = @Elm_Kernel_String_length, eco.cse_safe}
       : (!eco.value) -> !eco.value
    %z = arith.constant 0 : i64
    return %z : i64
  }
}

// CHECK: "eco.call"
// CHECK-SAME: callee = @Elm_Kernel_String_length
// CHECK-SAME: eco.cse_safe
