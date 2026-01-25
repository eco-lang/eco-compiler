// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test roundtrip of signed values (i8, i16, i32)

module {
  func.func @main() -> i64 {
    // Create buffer
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write negative values (stored as unsigned bit patterns)
    %neg1_i8 = arith.constant 255 : i64    // -1 as u8
    %cursor1 = bf.write.u8 %cursor0, %neg1_i8 : !bf.cursor

    %neg100_i16 = arith.constant 65436 : i64  // -100 as u16
    %cursor2 = bf.write.u16 %cursor1, %neg100_i16 (le) : !bf.cursor

    %neg1000_i32 = arith.constant 4294966296 : i64  // -1000 as u32
    %cursor3 = bf.write.u32 %cursor2, %neg1000_i32 (le) : !bf.cursor

    // Read back as signed
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r_i8, %read_cursor1 = bf.read.i8 %read_cursor0 : i64, !bf.cursor
    %r_i16, %read_cursor2 = bf.read.i16 %read_cursor1 (le) : i64, !bf.cursor
    %r_i32, %read_cursor3 = bf.read.i32 %read_cursor2 (le) : i64, !bf.cursor

    eco.dbg %r_i8 : i64
    // CHECK: -1
    eco.dbg %r_i16 : i64
    // CHECK: -100
    eco.dbg %r_i32 : i64
    // CHECK: -1000

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
