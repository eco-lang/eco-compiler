// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.i8 negative values (-128, -1)

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write bytes that represent negative i8 values
    // -128 = 0x80 (128), -1 = 0xFF (255)
    %v128 = arith.constant 128 : i64  // -128 as i8
    %cursor1 = bf.write.u8 %cursor0, %v128 : !bf.cursor
    %v255 = arith.constant 255 : i64  // -1 as i8
    %cursor2 = bf.write.u8 %cursor1, %v255 : !bf.cursor

    // Read back as signed
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r0, %read_cursor1 = bf.read.i8 %read_cursor0 : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.i8 %read_cursor1 : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: -128
    eco.dbg %r1 : i64
    // CHECK: -1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
