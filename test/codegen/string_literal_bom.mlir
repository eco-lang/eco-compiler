// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string starting with UTF-8 BOM (Byte Order Mark).
// BOM is U+FEFF, UTF-8 encoding: EF BB BF

module {
  func.func @main() -> i64 {
    // UTF-8 BOM followed by text
    // BOM: \xEF\xBB\xBF = U+FEFF
    %with_bom = eco.string_literal "\EF\BB\BFHello" : !eco.value
    eco.dbg %with_bom : !eco.value
    // BOM is typically invisible but valid
    // CHECK: [eco.dbg]

    // Just BOM
    %just_bom = eco.string_literal "\EF\BB\BF" : !eco.value
    eco.dbg %just_bom : !eco.value
    // CHECK: [eco.dbg]

    // BOM in middle of string (unusual but valid)
    %mid_bom = eco.string_literal "A\EF\BB\BFB" : !eco.value
    eco.dbg %mid_bom : !eco.value
    // CHECK: [eco.dbg]

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
