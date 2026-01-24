// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.u8 edge cases

module {
  func.func @main() -> i64 {
    // Create buffer with boundary values
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write: 0, 127, 128, 255
    %v0 = arith.constant 0 : i64
    %cursor1 = bf.write.u8 %cursor0, %v0 : !bf.cursor
    %v127 = arith.constant 127 : i64
    %cursor2 = bf.write.u8 %cursor1, %v127 : !bf.cursor
    %v128 = arith.constant 128 : i64
    %cursor3 = bf.write.u8 %cursor2, %v128 : !bf.cursor
    %v255 = arith.constant 255 : i64
    %cursor4 = bf.write.u8 %cursor3, %v255 : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r0, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r1, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    %r2, %read_cursor3 = bf.read.u8 %read_cursor2 : i64, !bf.cursor
    %r3, %read_cursor4 = bf.read.u8 %read_cursor3 : i64, !bf.cursor

    eco.dbg %r0 : i64
    // CHECK: 0
    eco.dbg %r1 : i64
    // CHECK: 127
    eco.dbg %r2 : i64
    // CHECK: 128
    eco.dbg %r3 : i64
    // CHECK: 255

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
