// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string literals with long strings (100+ characters).
// Tests large string allocation and global initialization.

module {
  func.func @main() -> i64 {
    // 100 character string (all 'a')
    %s100 = eco.string_literal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" : !eco.value
    eco.dbg %s100 : !eco.value
    // CHECK: "aaaa

    // 200 character string with pattern
    %s200 = eco.string_literal "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuv" : !eco.value
    eco.dbg %s200 : !eco.value
    // CHECK: "0123

    // String with repeated pattern
    %pattern = eco.string_literal "HelloWorld!HelloWorld!HelloWorld!HelloWorld!HelloWorld!HelloWorld!HelloWorld!HelloWorld!HelloWorld!HelloWorld!" : !eco.value
    eco.dbg %pattern : !eco.value
    // CHECK: "Hello

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
