// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test eco.string_literal with multi-byte UTF-8 sequences.
// Tests 2-byte and 3-byte sequences (BMP characters).
// Note: 4-byte sequences (emoji) may not be fully supported yet.

module {
  func.func @main() -> i64 {
    // 2-byte UTF-8: Latin-1 supplement
    // Copyright sign (U+00A9) = C2 A9
    %copyright = eco.string_literal "\C2\A9 2024" : !eco.value
    eco.dbg %copyright : !eco.value
    // CHECK: "

    // 2-byte UTF-8: Extended Latin
    // cafe with accent (U+00E9) = C3 A9
    %cafe = eco.string_literal "caf\C3\A9" : !eco.value
    eco.dbg %cafe : !eco.value
    // CHECK: "caf

    // 3-byte UTF-8: Greek lambda (U+03BB) = CE BB
    %greek = eco.string_literal "\CE\BB x. x" : !eco.value
    eco.dbg %greek : !eco.value
    // CHECK: "

    // 3-byte UTF-8: CJK characters
    // "Hello" in Chinese (ni hao) = E4 BD A0 E5 A5 BD
    %chinese = eco.string_literal "\E4\BD\A0\E5\A5\BD" : !eco.value
    eco.dbg %chinese : !eco.value
    // CHECK: "

    // 3-byte UTF-8: Euro sign (U+20AC) = E2 82 AC
    %euro = eco.string_literal "Price: \E2\82\AC100" : !eco.value
    eco.dbg %euro : !eco.value
    // CHECK: "Price:

    // 3-byte UTF-8: Mathematical symbols
    // Infinity (U+221E) = E2 88 9E
    %infinity = eco.string_literal "\E2\88\9E + 1 = \E2\88\9E" : !eco.value
    eco.dbg %infinity : !eco.value
    // CHECK: "

    // 3-byte UTF-8: Right arrow (U+2192) = E2 86 92
    %arrow = eco.string_literal "f: A \E2\86\92 B" : !eco.value
    eco.dbg %arrow : !eco.value
    // CHECK: "f: A

    // Mixed ASCII and multi-byte
    %mixed = eco.string_literal "Hello \E4\B8\96\E7\95\8C (world)" : !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: "Hello

    // String with multiple 3-byte characters in sequence
    %triple = eco.string_literal "\E2\98\85\E2\98\86\E2\98\85" : !eco.value
    eco.dbg %triple : !eco.value
    // CHECK: "

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
