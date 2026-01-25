// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.u32 with big-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write u32 big-endian (0xDEADBEEF = 3735928559)
    %val = arith.constant 3735928559 : i64
    %cursor1 = bf.write.u32 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %read_val, %read_cursor1 = bf.read.u32 %read_cursor0 (be) : i64, !bf.cursor

    eco.dbg %read_val : i64
    // CHECK: 3735928559

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
