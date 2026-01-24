// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test bf.write.utf8 with ASCII-only string
// XFAIL: Requires eco.value <-> i64 type interop in bf dialect

module {
  func.func @main() -> i64 {
    // Test UTF-8 width computation for ASCII
    // ASCII characters are 1 byte each in UTF-8
    %str = eco.string_literal "Hello" : !eco.value
    %width = bf.utf8_width %str : i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 5

    // Allocate buffer and write
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    %cursor1 = bf.write.utf8 %cursor0, %str : !bf.cursor

    // Read back first byte ('H' = 72)
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %r1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    eco.dbg %r1 : i64
    // CHECK: 72

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
