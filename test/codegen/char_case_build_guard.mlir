// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// Build-mismatch guard for ECO_CHAR_CASE_EXPANSION (KERN_008, CharValue::kBuildGuardSymbol,
// plans/char-case-mapping-elm-exact.md): the lowering calls the empty
// eco_char_case_expansion_on (or _off, in a build with the flag off) at the top of @main, and
// the runtime defines only the one of its own setting, so a program lowered with one setting
// fails to link against a runtime built with the other. Functions other than @main get no call.

module {
  func.func private @helper(%x: i64) -> i64 {
    eco.return %x : i64
  }

  func.func @main() -> i64 {
    %c = arith.constant 7 : i64
    %r = func.call @helper(%c) : (i64) -> i64
    return %r : i64
  }
}

// CHECK-LABEL: llvm.func @helper
// CHECK-NEXT: llvm.return %arg0 : i64
// CHECK-LABEL: llvm.func @main
// CHECK-NEXT: llvm.call @eco_char_case_expansion_{{on|off}}() : () -> ()
