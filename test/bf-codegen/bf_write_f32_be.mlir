// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.f32 with big-endian

module {
  func.func @main() -> i64 {
    // Allocate buffer
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write f32 big-endian (3.14159)
    %val = arith.constant 3.14159 : f64
    %cursor1 = bf.write.f32 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %read_val, %read_cursor1 = bf.read.f32 %read_cursor0 (be) : f64, !bf.cursor

    // Compare - f32 has limited precision, so round to ~5 decimal places
    // 3.14159 stored as f32 becomes approximately 3.1415901184082
    eco.dbg %read_val : f64
    // CHECK: 3.14159

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
