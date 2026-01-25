// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test successful decode returns Just (simulated)

module {
  func.func @main() -> i64 {
    // Create buffer with valid data
    %size = arith.constant 4 : i32
    %buffer = bf.alloc %size : i64
    %cursor0 = bf.cursor.init %buffer : i64 -> !bf.cursor

    %val = arith.constant 42 : i64
    %cursor1 = bf.write.u8 %cursor0, %val : !bf.cursor

    // Decode with bounds check
    %rc0 = bf.decoder.cursor.init %buffer : i64 -> !bf.cursor
    %needed = arith.constant 1 : i32
    %ok = bf.require %rc0, %needed : i1

    // If ok, read value (simulating Just)
    %result, %rc1 = bf.read.u8 %rc0 : i64, !bf.cursor

    // Success = 1 (Just semantics)
    %ok_int = arith.extui %ok : i1 to i64
    eco.dbg %ok_int : i64
    // CHECK: 1

    eco.dbg %result : i64
    // CHECK: 42

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
