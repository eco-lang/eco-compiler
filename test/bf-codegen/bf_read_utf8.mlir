// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.utf8 - read UTF-8 encoded string

module {
  func.func @main() -> i64 {
    // Create buffer with ASCII UTF-8 bytes "Hi"
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write "Hi" as UTF-8 bytes (ASCII)
    %h = arith.constant 72 : i64   // 'H'
    %cursor1 = bf.write.u8 %cursor0, %h : !bf.cursor
    %i = arith.constant 105 : i64  // 'i'
    %cursor2 = bf.write.u8 %cursor1, %i : !bf.cursor

    // Read 2 bytes as UTF-8
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %len = arith.constant 2 : i32
    %string, %read_cursor1, %ok = bf.read.utf8 %read_cursor0, %len : i64, !bf.cursor, i1

    // Verify ok flag
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // Check string UTF-8 width
    %width = bf.utf8_width %string : i64 -> i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
