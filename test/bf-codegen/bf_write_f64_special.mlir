// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.write.f64 special values: Inf, -Inf, 0.0

module {
  func.func @main() -> i64 {
    // Allocate buffer for 3 f64 values
    %size = arith.constant 24 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write special values
    %inf = arith.constant 0x7FF0000000000000 : i64
    %inf_f64 = arith.bitcast %inf : i64 to f64
    %cursor1 = bf.write.f64 %cursor0, %inf_f64 (le) : !bf.cursor

    %neg_inf = arith.constant 0xFFF0000000000000 : i64
    %neg_inf_f64 = arith.bitcast %neg_inf : i64 to f64
    %cursor2 = bf.write.f64 %cursor1, %neg_inf_f64 (le) : !bf.cursor

    %zero_f = arith.constant 0.0 : f64
    %cursor3 = bf.write.f64 %cursor2, %zero_f (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r0, %read_cursor1 = bf.read.f64 %read_cursor0 (le) : f64, !bf.cursor
    %r1, %read_cursor2 = bf.read.f64 %read_cursor1 (le) : f64, !bf.cursor
    %r2, %read_cursor3 = bf.read.f64 %read_cursor2 (le) : f64, !bf.cursor

    eco.dbg %r0 : f64
    // CHECK: Infinity
    eco.dbg %r1 : f64
    // CHECK: -Infinity
    eco.dbg %r2 : f64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
