// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test that eco.string_literal correctly handles strings that resemble
// internal MLIR location encodings. Regression test for bytecode
// encoder conflating location attrs with string attrs.

module {
  func.func @main() -> i64 {
    // String matching the unknown location magic prefix
    %s1 = eco.string_literal "__mlir_unknown_loc__" : !eco.value
    eco.dbg %s1 : !eco.value
    // CHECK: "__mlir_unknown_loc__"

    // String matching the file location magic prefix
    %s2 = eco.string_literal "__mlir_loc__:test:1:2" : !eco.value
    eco.dbg %s2 : !eco.value
    // CHECK: "__mlir_loc__:test:1:2"

    // String with just the prefix
    %s3 = eco.string_literal "__mlir_loc__:" : !eco.value
    eco.dbg %s3 : !eco.value
    // CHECK: "__mlir_loc__:"

    // The key that the old code produced
    %s4 = eco.string_literal "loc:unknown" : !eco.value
    eco.dbg %s4 : !eco.value
    // CHECK: "loc:unknown"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
