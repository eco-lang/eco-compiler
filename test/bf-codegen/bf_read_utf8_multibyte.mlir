// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.utf8 with multi-byte UTF-8 characters

module {
  func.func @main() -> i64 {
    // Create buffer with "é" encoded as UTF-8 (0xC3 0xA9)
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write UTF-8 encoding of "é"
    %b1 = arith.constant 195 : i64  // 0xC3
    %cursor1 = bf.write.u8 %cursor0, %b1 : !bf.cursor
    %b2 = arith.constant 169 : i64  // 0xA9
    %cursor2 = bf.write.u8 %cursor1, %b2 : !bf.cursor

    // Read 2 bytes as UTF-8
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %len = arith.constant 2 : i32
    %string, %read_cursor1, %ok = bf.read.utf8 %read_cursor0, %len : i64, !bf.cursor, i1

    // Verify ok flag (valid UTF-8)
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // The string "é" should have UTF-8 width of 2
    %width = bf.utf8_width %string : i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
