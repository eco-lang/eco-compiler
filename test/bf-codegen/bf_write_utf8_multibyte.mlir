// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test bf.write.utf8 with multi-byte UTF-8 characters
// XFAIL: Requires eco.value <-> i64 type interop in bf dialect

module {
  func.func @main() -> i64 {
    // Test with string containing multi-byte characters
    // "é" (U+00E9) encodes as 2 bytes: 0xC3 0xA9
    // "日" (U+65E5) encodes as 3 bytes: 0xE6 0x97 0xA5
    %str = eco.string_literal "\C3\A9" : !eco.value
    %width = bf.utf8_width %str : i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 2

    // Allocate buffer and write
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    %cursor1 = bf.write.utf8 %cursor0, %str : !bf.cursor

    // Read back first byte (0xC3 = 195)
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    eco.dbg %r1 : i64
    // CHECK: 195

    // Read second byte (0xA9 = 169)
    %r2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    eco.dbg %r2 : i64
    // CHECK: 169

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
