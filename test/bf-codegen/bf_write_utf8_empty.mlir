// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test bf.write.utf8 with empty string
// XFAIL: Requires eco.value <-> i64 type interop in bf dialect

module {
  func.func @main() -> i64 {
    // Empty string should have 0 UTF-8 width
    %str = eco.string_literal "" : !eco.value
    %width = bf.utf8_width %str : i64 -> i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 0

    // Allocate buffer and write empty string
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    // Write marker before
    %marker1 = arith.constant 0xAA : i64
    %cursor1 = bf.write.u8 %cursor0, %marker1 : !bf.cursor

    // Write empty string (should not advance cursor)
    %cursor2 = bf.write.utf8 %cursor1, %str : !bf.cursor

    // Write marker after
    %marker2 = arith.constant 0xBB : i64
    %cursor3 = bf.write.u8 %cursor2, %marker2 : !bf.cursor

    // Read back - markers should be adjacent
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    %r2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor

    eco.dbg %r1 : i64
    // CHECK: 170
    eco.dbg %r2 : i64
    // CHECK: 187

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
