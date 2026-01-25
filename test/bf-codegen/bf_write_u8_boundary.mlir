// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.u8 edge cases: 0, 127, 255

module {
  func.func @main() -> i64 {
    // Allocate buffer for 3 bytes
    %size = arith.constant 3 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write boundary values
    %val0 = arith.constant 0 : i64
    %cursor1 = bf.write.u8 %cursor0, %val0 : !bf.cursor

    %val127 = arith.constant 127 : i64
    %cursor2 = bf.write.u8 %cursor1, %val127 : !bf.cursor

    %val255 = arith.constant 255 : i64
    %cursor3 = bf.write.u8 %cursor2, %val255 : !bf.cursor

    // Read back all values
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r0, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    %r2, %read_cursor3 = bf.read.u8 %read_cursor2 : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: 0
    eco.dbg %r1 : i64
    // CHECK: 127
    eco.dbg %r2 : i64
    // CHECK: 255

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
