// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.f32 special values: Inf, -Inf, 0.0, -0.0

module {
  func.func @main() -> i64 {
    // Allocate buffer for 4 f32 values
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write special values (little-endian)
    %inf = arith.constant 0x7FF0000000000000 : i64  // +Inf as f64 bits
    %inf_f64 = arith.bitcast %inf : i64 to f64
    %cursor1 = bf.write.f32 %cursor0, %inf_f64 (le) : !bf.cursor

    %neg_inf = arith.constant 0xFFF0000000000000 : i64  // -Inf as f64 bits
    %neg_inf_f64 = arith.bitcast %neg_inf : i64 to f64
    %cursor2 = bf.write.f32 %cursor1, %neg_inf_f64 (le) : !bf.cursor

    %zero_f = arith.constant 0.0 : f64
    %cursor3 = bf.write.f32 %cursor2, %zero_f (le) : !bf.cursor

    %neg_zero = arith.constant -0.0 : f64
    %cursor4 = bf.write.f32 %cursor3, %neg_zero (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r0, %read_cursor1 = bf.read.f32 %read_cursor0 (le) : f64, !bf.cursor
    %r1, %read_cursor2 = bf.read.f32 %read_cursor1 (le) : f64, !bf.cursor
    %r2, %read_cursor3 = bf.read.f32 %read_cursor2 (le) : f64, !bf.cursor
    %r3, %read_cursor4 = bf.read.f32 %read_cursor3 (le) : f64, !bf.cursor

    eco.dbg %r0 : f64
    // CHECK: Infinity
    eco.dbg %r1 : f64
    // CHECK: -Infinity
    eco.dbg %r2 : f64
    // CHECK: 0
    eco.dbg %r3 : f64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
