// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.require fails at end of buffer

module {
  func.func @main() -> i64 {
    // Create buffer with 4 bytes
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor

    // Read all 4 bytes to advance cursor to end
    %v1, %cursor1 = bf.read.u8 %cursor0 : i64, !bf.cursor
    %v2, %cursor2 = bf.read.u8 %cursor1 : i64, !bf.cursor
    %v3, %cursor3 = bf.read.u8 %cursor2 : i64, !bf.cursor
    %v4, %cursor4 = bf.read.u8 %cursor3 : i64, !bf.cursor

    // Now require 1 more byte (should fail)
    %req_bytes = arith.constant 1 : i32
    %ok = bf.require %cursor4, %req_bytes : i1

    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
