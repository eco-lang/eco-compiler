// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test reading multiple values sequentially with cursor threading

module {
  func.func @main() -> i64 {
    // Create buffer with various types
    %size = arith.constant 20 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write: u8, i16, u32, f64
    %v_u8 = arith.constant 99 : i64
    %cursor1 = bf.write.u8 %cursor0, %v_u8 : !bf.cursor

    %v_i16 = arith.constant 30000 : i64
    %cursor2 = bf.write.u16 %cursor1, %v_i16 (le) : !bf.cursor

    %v_u32 = arith.constant 1000000 : i64
    %cursor3 = bf.write.u32 %cursor2, %v_u32 (le) : !bf.cursor

    %v_f64 = arith.constant 2.5 : f64
    %cursor4 = bf.write.f64 %cursor3, %v_f64 (le) : !bf.cursor

    // Read back sequence
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r_u8, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r_i16, %read_cursor2 = bf.read.i16 %read_cursor1 (le) : i64, !bf.cursor
    %r_u32, %read_cursor3 = bf.read.u32 %read_cursor2 (le) : i64, !bf.cursor
    %r_f64, %read_cursor4 = bf.read.f64 %read_cursor3 (le) : f64, !bf.cursor

    eco.dbg %r_u8 : i64
    // CHECK: 99
    eco.dbg %r_i16 : i64
    // CHECK: 30000
    eco.dbg %r_u32 : i64
    // CHECK: 1000000
    eco.dbg %r_f64 : f64
    // CHECK: 2.5

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
