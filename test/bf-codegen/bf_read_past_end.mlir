// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test attempting to read past buffer end (bounds check)

module {
  func.func @main() -> i64 {
    // Create small buffer
    %size = arith.constant 2 : i32
    %buffer = bf.alloc %size : i64

    %cursor = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor

    // Check if we can read 4 bytes (should fail)
    %needed = arith.constant 4 : i32
    %ok = bf.require %cursor, %needed : i1
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 0

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
