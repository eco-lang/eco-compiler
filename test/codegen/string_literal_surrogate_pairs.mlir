// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test string literals with characters requiring UTF-16 surrogate pairs.
// Codepoints > U+FFFF need two UTF-16 code units (surrogate pair).

module {
  func.func @main() -> i64 {
    // Emoji: U+1F600 (Grinning Face) - requires surrogate pair
    // UTF-8: F0 9F 98 80
    // UTF-16: D83D DE00 (surrogate pair)
    %emoji = eco.string_literal "\F0\9F\98\80" : !eco.value
    eco.dbg %emoji : !eco.value
    // CHECK: [eco.dbg] "\uD83D\uDE00"

    // Multiple emoji
    %multi = eco.string_literal "\F0\9F\98\80\F0\9F\98\81" : !eco.value
    eco.dbg %multi : !eco.value
    // CHECK: [eco.dbg] "\uD83D\uDE00\uD83D\uDE01"

    // Mix of BMP and non-BMP characters
    // "A" (U+0041) + emoji (U+1F600) + "B" (U+0042)
    %mixed = eco.string_literal "A\F0\9F\98\80B" : !eco.value
    eco.dbg %mixed : !eco.value
    // CHECK: [eco.dbg] "A\uD83D\uDE00B"

    // Mathematical symbols outside BMP: U+1D400 (Mathematical Bold Capital A)
    // UTF-8: F0 9D 90 80
    %math = eco.string_literal "\F0\9D\90\80" : !eco.value
    eco.dbg %math : !eco.value
    // CHECK: [eco.dbg] "\uD835\uDC00"

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
