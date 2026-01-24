// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip: write f32 LE, read back, verify match

module {
  func.func @main() -> i64 {
    %val = arith.constant -2.25 : f64

    // Create buffer and write
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor
    %cursor1 = bf.write.f32 %cursor0, %val (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %result, %read_cursor1 = bf.read.f32 %read_cursor0 (le) : f64, !bf.cursor

    // Verify match (-2.25 is exactly representable)
    %match = arith.cmpf oeq, %val, %result : f64
    %match_int = arith.extui %match : i1 to i64
    eco.dbg %match_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
