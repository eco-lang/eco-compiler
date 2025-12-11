// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.string_literal with longer strings.

module {
  func.func @main() -> i64 {
    // Longer ASCII string
    %sentence = eco.string_literal "The quick brown fox jumps over the lazy dog." : !eco.value
    eco.dbg %sentence : !eco.value
    // CHECK: "The quick brown fox jumps over the lazy dog."

    // Repeated character
    %repeated = eco.string_literal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" : !eco.value
    eco.dbg %repeated : !eco.value
    // CHECK: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    // String with various whitespace
    %whitespace = eco.string_literal "line1\0Aline2\0Aline3\09tabbed" : !eco.value
    eco.dbg %whitespace : !eco.value
    // CHECK: "line1

    // String with special characters
    %special = eco.string_literal "Hello \"world\"! It's <awesome> & fun." : !eco.value
    eco.dbg %special : !eco.value
    // CHECK: "Hello

    // Numbers and symbols
    %nums = eco.string_literal "0123456789!@#$%^&*()_+-=[]{}|;':,./<>?" : !eco.value
    eco.dbg %nums : !eco.value
    // CHECK: "0123456789

    // All lowercase letters
    %lower = eco.string_literal "abcdefghijklmnopqrstuvwxyz" : !eco.value
    eco.dbg %lower : !eco.value
    // CHECK: "abcdefghijklmnopqrstuvwxyz"

    // All uppercase letters
    %upper = eco.string_literal "ABCDEFGHIJKLMNOPQRSTUVWXYZ" : !eco.value
    eco.dbg %upper : !eco.value
    // CHECK: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

    // Lorem ipsum paragraph (about 200 chars)
    %lorem = eco.string_literal "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris." : !eco.value
    eco.dbg %lorem : !eco.value
    // CHECK: "Lorem ipsum dolor sit amet

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
