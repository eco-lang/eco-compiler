// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.f64 with little-endian

module {
  func.func @main() -> i64 {
    // Allocate buffer
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write f64 little-endian (2.718281828459045)
    %val = arith.constant 2.718281828459045 : f64
    %cursor1 = bf.write.f64 %cursor0, %val (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %read_val, %read_cursor1 = bf.read.f64 %read_cursor0 (le) : f64, !bf.cursor

    eco.dbg %read_val : f64
    // CHECK: 2.71828

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
