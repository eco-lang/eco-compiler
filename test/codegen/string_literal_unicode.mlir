// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.string_literal with UTF-8 input (converted to UTF-16 internally).

module {
  func.func @main() -> i64 {
    // Latin extended: cafe with accent
    %cafe = eco.string_literal "caf\C3\A9" : !eco.value
    eco.dbg %cafe : !eco.value
    // CHECK: "caf

    // Greek letters (lambda alpha mu beta delta alpha)
    %greek = eco.string_literal "\CE\BB\CE\B1\CE\BC\CE\B2\CE\B4\CE\B1" : !eco.value
    eco.dbg %greek : !eco.value
    // CHECK: "

    // Chinese characters (ni hao = hello)
    %chinese = eco.string_literal "\E4\BD\A0\E5\A5\BD" : !eco.value
    eco.dbg %chinese : !eco.value
    // CHECK: "

    // Mixed ASCII and unicode
    %mixed = eco.string_literal "Hello \E4\B8\96\E7\95\8C" : !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: "Hello

    // Euro sign
    %euro = eco.string_literal "Price: \E2\82\AC100" : !eco.value
    eco.dbg %euro : !eco.value
    // CHECK: "Price:

    // Math symbols (lambda x arrow x)
    %lambda = eco.string_literal "\CE\BB x \E2\86\92 x" : !eco.value
    eco.dbg %lambda : !eco.value
    // CHECK: "

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
