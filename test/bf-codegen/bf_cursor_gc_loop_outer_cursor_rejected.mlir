// RUN: not %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s
//
// BFOPS_039 structural check: a cursor defined outside a loop that may run a
// GC, and used inside it without being threaded through the loop's iteration
// arguments, is stale from the second iteration on; no rebase placed inside
// one iteration can fix it, so BFToLLVM rejects the function. (Fused code
// threads every cursor through scf.while, BFOPS_002.)

// CHECK: a cursor is used after an op that may run a GC without being re-derived (BFOPS_039): scf.for

module {
  llvm.func @eco_minor_gc()

  func.func @main() -> i64 {
    %n = arith.constant 4 : i32
    %buf = bf.alloc %n : !eco.value
    %c0 = bf.decoder.cursor.init %buf : !eco.value -> !bf.cursor
    %lb = arith.constant 0 : index
    %ub = arith.constant 2 : index
    %step = arith.constant 1 : index
    %zero = arith.constant 0 : i64
    %r = scf.for %i = %lb to %ub step %step iter_args(%acc = %zero) -> (i64) {
      %a, %c1 = bf.read.u8 %c0 : i64, !bf.cursor
      llvm.call @eco_minor_gc() : () -> ()
      %s = arith.addi %acc, %a : i64
      scf.yield %s : i64
    }
    %w = bf.bytes_width %buf : !eco.value -> i32
    return %r : i64
  }
}
