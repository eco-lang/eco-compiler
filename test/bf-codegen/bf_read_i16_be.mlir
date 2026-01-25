// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.i16 signed big-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write values that will be negative when read as i16
    // -1 = 0xFFFF, -32768 = 0x8000
    %neg1 = arith.constant 65535 : i64  // 0xFFFF
    %cursor1 = bf.write.u16 %cursor0, %neg1 (be) : !bf.cursor
    %neg32768 = arith.constant 32768 : i64  // 0x8000
    %cursor2 = bf.write.u16 %cursor1, %neg32768 (be) : !bf.cursor

    // Read back as signed
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r0, %read_cursor1 = bf.read.i16 %read_cursor0 (be) : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.i16 %read_cursor1 (be) : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: -1
    eco.dbg %r1 : i64
    // CHECK: -32768

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
