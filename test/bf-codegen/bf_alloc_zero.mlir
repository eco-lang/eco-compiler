// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test bf.alloc with zero bytes - should return valid empty buffer

module {
  func.func @main() -> i64 {
    // Allocate empty buffer (0 bytes)
    %size = arith.constant 0 : i32
    %buffer = bf.alloc %size : !eco.value

    // Verify buffer is a valid allocation by initializing a cursor
    %c0 = bf.cursor.init %buffer : !eco.value -> !bf.cursor

    // Require 0 bytes should succeed on empty buffer
    %needed = arith.constant 0 : i32
    %ok = bf.require %c0, %needed : i1
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
