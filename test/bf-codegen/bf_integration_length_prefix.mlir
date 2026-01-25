// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test length-prefixed string roundtrip:
// XFAIL: Requires eco.value <-> i64 type interop in bf dialect
// [length: u32] [utf8_bytes]

module {
  func.func @main() -> i64 {
    // Create string "ABC"
    %str = eco.string_literal "ABC" : !eco.value

    // Get UTF-8 width
    %width = bf.utf8_width %str : i64 -> i32
    %width64 = arith.extsi %width : i32 to i64

    // Allocate buffer: 4 (length) + width
    %four = arith.constant 4 : i32
    %total = arith.addi %four, %width : i32
    %buffer = bf.alloc %total : i64
    %c0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write length prefix
    %c1 = bf.write.u32 %c0, %width64 (le) : !bf.cursor

    // Write UTF-8 string
    %c2 = bf.write.utf8 %c1, %str : !bf.cursor

    // Decode: read length then string
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %read_len, %rc1 = bf.read.u32 %rc0 (le) : i64, !bf.cursor

    eco.dbg %read_len : i64
    // CHECK: 3

    // Read UTF-8 string
    %read_len32 = arith.trunci %read_len : i64 to i32
    %read_str, %rc2, %ok = bf.read.utf8 %rc1, %read_len32 : i64, !bf.cursor, i1

    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // Verify string has same UTF-8 width
    %result_width = bf.utf8_width %read_str : i64 -> i32
    %result_width64 = arith.extsi %result_width : i32 to i64
    eco.dbg %result_width64 : i64
    // CHECK: 3

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
