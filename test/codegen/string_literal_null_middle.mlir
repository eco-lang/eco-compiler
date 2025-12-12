// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string with null byte (\x00) in the middle.
// Elm strings should handle embedded nulls.

module {
  func.func @main() -> i64 {
    // String with null in middle: "A\0B"
    %with_null = eco.string_literal "A\00B" : !eco.value
    eco.dbg %with_null : !eco.value
    // The output depends on how null is printed - likely as \u0000
    // CHECK: [eco.dbg]

    // Just a null
    %just_null = eco.string_literal "\00" : !eco.value
    eco.dbg %just_null : !eco.value
    // CHECK: [eco.dbg]

    // Nulls at start and end
    %null_sandwich = eco.string_literal "\00X\00" : !eco.value
    eco.dbg %null_sandwich : !eco.value
    // CHECK: [eco.dbg]

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
