// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.bytes with zero length

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write some data
    %v = arith.constant 0xFF : i64
    %cursor1 = bf.write.u8 %cursor0, %v : !bf.cursor

    // Read 0 bytes
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %len = arith.constant 0 : i32
    %bytes, %read_cursor1, %ok = bf.read.bytes %read_cursor0, %len : i64, !bf.cursor, i1

    // Verify ok flag
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // Empty bytes should have width 0
    %width = bf.bytes_width %bytes : i64 -> i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
