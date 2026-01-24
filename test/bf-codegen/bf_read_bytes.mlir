// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.bytes - read bytes with known length

module {
  func.func @main() -> i64 {
    // Create buffer with some bytes
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write known byte pattern
    %v1 = arith.constant 0x11 : i64
    %cursor1 = bf.write.u8 %cursor0, %v1 : !bf.cursor
    %v2 = arith.constant 0x22 : i64
    %cursor2 = bf.write.u8 %cursor1, %v2 : !bf.cursor
    %v3 = arith.constant 0x33 : i64
    %cursor3 = bf.write.u8 %cursor2, %v3 : !bf.cursor
    %v4 = arith.constant 0x44 : i64
    %cursor4 = bf.write.u8 %cursor3, %v4 : !bf.cursor

    // Read 4 bytes
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %len = arith.constant 4 : i32
    %bytes, %read_cursor1, %ok = bf.read.bytes %read_cursor0, %len : i64, !bf.cursor, i1

    // Verify ok flag
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // Read back from the new ByteBuffer
    %new_read_cursor = bf.decoder.cursor.init %bytes : !bf.cursor
    %r1, %new_read_cursor1 = bf.read.u8 %new_read_cursor : i64, !bf.cursor
    eco.dbg %r1 : i64
    // CHECK: 17

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
