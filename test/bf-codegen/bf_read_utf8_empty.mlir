// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.utf8 with zero length (empty string)

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64

    // Read 0 bytes as UTF-8
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %len = arith.constant 0 : i32
    %string, %read_cursor1, %ok = bf.read.utf8 %read_cursor0, %len : i64, !bf.cursor, i1

    // Verify ok flag
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // Empty string should have UTF-8 width of 0
    %width = bf.utf8_width %string : i64 -> i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
