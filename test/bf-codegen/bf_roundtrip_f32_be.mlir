// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip: write f32 BE, read back, verify match

module {
  func.func @main() -> i64 {
    %val = arith.constant 1.5 : f64

    // Create buffer and write
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor
    %cursor1 = bf.write.f32 %cursor0, %val (be) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %result, %read_cursor1 = bf.read.f32 %read_cursor0 (be) : f64, !bf.cursor

    // Verify match (1.5 is exactly representable)
    %match = arith.cmpf oeq, %val, %result : f64
    %match_int = arith.extui %match : i1 to i64
    eco.dbg %match_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
