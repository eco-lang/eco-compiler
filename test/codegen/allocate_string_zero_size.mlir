// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.allocate_string with length 0 (empty string allocation).
//
// HEAP_071: a length-0 string is never a heap object — it is the embedded
// Empty constant. The untyped eco.dbg printer shows the constant as <empty>;
// a zero-length heap Tag_String would print as "" instead (and would compare
// unequal to "").

module {
  func.func @main() -> i64 {
    // Allocate an empty string
    %empty = eco.allocate_string {length = 0 : i64} : !eco.value
    eco.dbg %empty : !eco.value
    // CHECK: [eco.dbg] <empty>

    // Allocate another empty string
    %empty2 = eco.allocate_string {length = 0 : i64} : !eco.value
    eco.dbg %empty2 : !eco.value
    // CHECK: [eco.dbg] <empty>

    // For comparison, allocate a non-empty string
    %str = eco.string_literal "hello" : !eco.value
    eco.dbg %str : !eco.value
    // CHECK: "hello"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}

// CHECK-NOT: [eco.dbg] ""
