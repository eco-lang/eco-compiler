// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.read.f64 with big-endian

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write f64 big-endian (1.7976931348623157e+308 - close to max f64)
    %val = arith.constant 1.23456789012345678 : f64
    %cursor1 = bf.write.f64 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %read_val, %read_cursor1 = bf.read.f64 %read_cursor0 (be) : f64, !bf.cursor

    eco.dbg %read_val : f64
    // CHECK: 1.23457

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
