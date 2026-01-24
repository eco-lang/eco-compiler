// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.u8 - read single unsigned 8-bit value

module {
  func.func @main() -> i64 {
    // Create buffer with known value
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    %val = arith.constant 200 : i64
    %cursor1 = bf.write.u8 %cursor0, %val : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_val, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor

    eco.dbg %read_val : i64
    // CHECK: 200

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
