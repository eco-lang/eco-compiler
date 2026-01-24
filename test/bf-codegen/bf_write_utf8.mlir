// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test bf.write.utf8 - write string as UTF-8 bytes
// XFAIL: Requires eco.value <-> i64 type interop in bf dialect

module {
  func.func @main() -> i64 {
    // Create a string "Hi"
    %str = eco.string_literal "Hi" : !eco.value

    // Get UTF-8 width (should be 2 for "Hi")
    %width = bf.utf8_width %str : !eco.value -> i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 2

    // Allocate buffer for UTF-8 output
    %size = arith.constant 16 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : !bf.cursor

    // Write "Hi" as UTF-8
    %cursor1 = bf.write.utf8 %cursor0, %str : !eco.value -> !bf.cursor

    // Read back first byte ('H' = 72)
    %read_cursor0 = bf.decoder.cursor.init %buffer : !bf.cursor
    %byte1, %read_cursor1 = bf.read.u8 %read_cursor0 : i64, !bf.cursor
    eco.dbg %byte1 : i64
    // CHECK: 72

    // Read back second byte ('i' = 105)
    %byte2, %read_cursor2 = bf.read.u8 %read_cursor1 : i64, !bf.cursor
    eco.dbg %byte2 : i64
    // CHECK: 105

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
