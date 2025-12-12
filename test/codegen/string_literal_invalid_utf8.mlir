// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string with invalid UTF-8 byte sequences.
// Invalid bytes should be replaced with U+FFFD replacement character.

module {
  func.func @main() -> i64 {
    // Invalid UTF-8: 0x80 is a continuation byte without a lead byte
    // Should produce replacement character U+FFFD
    %invalid1 = eco.string_literal "\80" : !eco.value
    eco.dbg %invalid1 : !eco.value
    // CHECK: [eco.dbg] "\uFFFD"

    // Invalid UTF-8: 0xFF is never valid in UTF-8
    %invalid2 = eco.string_literal "\FF" : !eco.value
    eco.dbg %invalid2 : !eco.value
    // CHECK: [eco.dbg] "\uFFFD"

    // Mixed valid and invalid: A + invalid + B
    %mixed = eco.string_literal "A\80B" : !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: [eco.dbg] "A\uFFFDB"

    // Valid ASCII still works
    %valid = eco.string_literal "Hello" : !eco.value
    eco.dbg %valid : !eco.value
    // CHECK: [eco.dbg] "Hello"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
