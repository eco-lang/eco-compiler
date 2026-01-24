// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.u16 with big-endian

module {
  func.func @main() -> i64 {
    // Allocate buffer
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write u16 big-endian (0x1234 = 4660)
    %val = arith.constant 4660 : i64
    %cursor1 = bf.write.u16 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_val, %read_cursor1 = bf.read.u16 %read_cursor0 (be) : i64, !bf.cursor

    eco.dbg %read_val : i64
    // CHECK: 4660

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
