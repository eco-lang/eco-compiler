// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.f32 with big-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write f32 big-endian (1.5)
    %val = arith.constant 1.5 : f64
    %cursor1 = bf.write.f32 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_val, %read_cursor1 = bf.read.f32 %read_cursor0 (be) : f64, !bf.cursor

    eco.dbg %read_val : f64
    // CHECK: 1.5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
