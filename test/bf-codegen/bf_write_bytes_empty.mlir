// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.bytes with empty ByteBuffer

module {
  func.func @main() -> i64 {
    // Create empty source ByteBuffer
    %src_size = arith.constant 0 : i32
    %src_buffer = bf.alloc %src_size : i64

    // Create destination buffer
    %dst_size = arith.constant 4 : i32
    %dst_buffer = bf.alloc %dst_size : i64
    %dst_cursor0 = bf.cursor.init %dst_buffer : !bf.cursor

    // Write a marker first
    %marker = arith.constant 0xFF : i64
    %dst_cursor1 = bf.write.u8 %dst_cursor0, %marker : !bf.cursor

    // Copy empty bytes (should not advance cursor)
    %dst_cursor2 = bf.write.bytes %dst_cursor1, %src_buffer : !bf.cursor

    // Write another marker
    %marker2 = arith.constant 0xEE : i64
    %dst_cursor3 = bf.write.u8 %dst_cursor2, %marker2 : !bf.cursor

    // Read back - should see both markers adjacent
    %read_cursor0 = bf.decoder.cursor.init %dst_buffer : !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 255
    eco.dbg %r2 : i64
    // CHECK: 238

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
