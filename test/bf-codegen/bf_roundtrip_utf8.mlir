// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
// XFAIL: *
//
// Test roundtrip: write UTF-8 string, read back
// XFAIL: Requires eco.value <-> i64 type interop in bf dialect

module {
  func.func @main() -> i64 {
    // Create string "Hi"
    %str = eco.string_literal "Hi" : !eco.value

    // Get UTF-8 width
    %width = bf.utf8_width %str : i64 -> i32
    %width64 = arith.extsi %width : i32 to i64
    eco.dbg %width64 : i64
    // CHECK: 2

    // Allocate buffer and write
    %size = arith.constant 8 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor
    %cursor1 = bf.write.utf8 %cursor0, %str : !bf.cursor

    // Read back as UTF-8
    %read_cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %result_str, %read_cursor1, %ok = bf.read.utf8 %read_cursor0, %width : i64, !bf.cursor, i1

    // Verify ok
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    // Verify result has same UTF-8 width
    %result_width = bf.utf8_width %result_str : i64 -> i32
    %result_width64 = arith.extsi %result_width : i32 to i64
    eco.dbg %result_width64 : i64
    // CHECK: 2

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
