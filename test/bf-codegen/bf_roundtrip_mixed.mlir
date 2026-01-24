// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip of mixed types in sequence

module {
  func.func @main() -> i64 {
    // Create buffer for: u8 + u16 + u32 + f32 + f64 = 1+2+4+4+8 = 19 bytes
    %size = arith.constant 24 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write mixed sequence
    %v_u8 = arith.constant 42 : i64
    %cursor1 = bf.write.u8 %cursor0, %v_u8 : !bf.cursor

    %v_u16 = arith.constant 1234 : i64
    %cursor2 = bf.write.u16 %cursor1, %v_u16 (be) : !bf.cursor

    %v_u32 = arith.constant 56789 : i64
    %cursor3 = bf.write.u32 %cursor2, %v_u32 (le) : !bf.cursor

    %v_f32 = arith.constant 1.25 : f64
    %cursor4 = bf.write.f32 %cursor3, %v_f32 (be) : !bf.cursor

    %v_f64 = arith.constant 9.875 : f64
    %cursor5 = bf.write.f64 %cursor4, %v_f64 (le) : !bf.cursor

    // Read back
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r_u8, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r_u16, %read_cursor2 = bf.read.u16 %read_cursor1 (be) : i64, !bf.cursor
    %r_u32, %read_cursor3 = bf.read.u32 %read_cursor2 (le) : i64, !bf.cursor
    %r_f32, %read_cursor4 = bf.read.f32 %read_cursor3 (be) : f64, !bf.cursor
    %r_f64, %read_cursor5 = bf.read.f64 %read_cursor4 (le) : f64, !bf.cursor

    // Verify all values
    %m1 = arith.cmpi eq, %v_u8, %r_u8 : i64
    %m2 = arith.cmpi eq, %v_u16, %r_u16 : i64
    %m3 = arith.cmpi eq, %v_u32, %r_u32 : i64
    %m4 = arith.cmpf oeq, %v_f32, %r_f32 : f64
    %m5 = arith.cmpf oeq, %v_f64, %r_f64 : f64

    %all = arith.andi %m1, %m2 : i1
    %all2 = arith.andi %all, %m3 : i1
    %all3 = arith.andi %all2, %m4 : i1
    %all4 = arith.andi %all3, %m5 : i1
    %result = arith.extui %all4 : i1 to i64
    eco.dbg %result : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
