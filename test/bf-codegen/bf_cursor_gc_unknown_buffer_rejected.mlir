// RUN: not %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// BFOPS_039: a cursor live across an op that may run a GC is re-derived from
// its buffer. A cursor whose buffer the lowering cannot find (here a function
// argument) cannot be, so BFToLLVM rejects it instead of lowering a cursor
// that a GC could leave pointing at evacuated memory.

// CHECK: its buffer is unknown, so it cannot be re-derived (BFOPS_039)

module {
  llvm.func @eco_minor_gc()

  func.func @write_after_gc(%c0: !bf.cursor) -> i64 {
    llvm.call @eco_minor_gc() : () -> ()
    %v = arith.constant 7 : i64
    %c1 = bf.write.u8 %c0, %v : !bf.cursor
    %zero = arith.constant 0 : i64
    return %zero : i64
  }

  func.func @main() -> i64 {
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
