// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test writing multiple values sequentially with cursor threading

module {
  func.func @main() -> i64 {
    // Allocate buffer: 1 + 2 + 4 + 8 = 15 bytes
    %size = arith.constant 15 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write sequence: u8, u16, u32, f64
    %val_u8 = arith.constant 42 : i64
    %cursor1 = bf.write.u8 %cursor0, %val_u8 : !bf.cursor

    %val_u16 = arith.constant 1234 : i64
    %cursor2 = bf.write.u16 %cursor1, %val_u16 (le) : !bf.cursor

    %val_u32 = arith.constant 567890 : i64
    %cursor3 = bf.write.u32 %cursor2, %val_u32 (le) : !bf.cursor

    %val_f64 = arith.constant 3.14 : f64
    %cursor4 = bf.write.f64 %cursor3, %val_f64 (le) : !bf.cursor

    // Read back all values
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r_u8, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r_u16, %read_cursor2 = bf.read.u16 %read_cursor1 (le) : i64, !bf.cursor
    %r_u32, %read_cursor3 = bf.read.u32 %read_cursor2 (le) : i64, !bf.cursor
    %r_f64, %read_cursor4 = bf.read.f64 %read_cursor3 (le) : f64, !bf.cursor

    eco.dbg %r_u8 : i64
    // CHECK: 42
    eco.dbg %r_u16 : i64
    // CHECK: 1234
    eco.dbg %r_u32 : i64
    // CHECK: 567890
    eco.dbg %r_f64 : f64
    // CHECK: 3.14

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
