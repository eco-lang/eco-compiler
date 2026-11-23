// RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=IR
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT
//
// eco.int.bitmap_index and eco.int.popcount32 (eco/system's Bitmap.index and Bitmap.popCount32,
// plans/seq-data-structures-performance.md A1) lower to llvm.intr.ctpop, read only the low 32 bits of
// the bitmap and take the bit index mod 32. The arguments go through calls so nothing folds.

// IR-LABEL: llvm.func {{.*}}@index
// IR: llvm.intr.ctpop
// IR-LABEL: llvm.func {{.*}}@pop
// IR: llvm.intr.ctpop

module {
  func.func private @index(%b: i64, %i: i64) -> i64 {
    %r = eco.int.bitmap_index %b, %i : i64
    eco.return %r : i64
  }

  func.func private @pop(%x: i64) -> i64 {
    %r = eco.int.popcount32 %x : i64
    eco.return %r : i64
  }

  func.func @main() -> i64 {
    %b0 = arith.constant 4294967295 : i64
    %i0 = arith.constant 0 : i64
    %r0 = func.call @index(%b0, %i0) : (i64, i64) -> i64
    %x0 = eco.box %r0 : i64 -> !eco.value
    eco.dbg %x0 : !eco.value
    // JIT: 0
    %b1 = arith.constant 4294967295 : i64
    %i1 = arith.constant 31 : i64
    %r1 = func.call @index(%b1, %i1) : (i64, i64) -> i64
    %x1 = eco.box %r1 : i64 -> !eco.value
    eco.dbg %x1 : !eco.value
    // JIT: 31
    %b2 = arith.constant 4294967299 : i64
    %i2 = arith.constant 2 : i64
    %r2 = func.call @index(%b2, %i2) : (i64, i64) -> i64
    %x2 = eco.box %r2 : i64 -> !eco.value
    eco.dbg %x2 : !eco.value
    // JIT: 2
    %b3 = arith.constant 7 : i64
    %i3 = arith.constant -1 : i64
    %r3 = func.call @index(%b3, %i3) : (i64, i64) -> i64
    %x3 = eco.box %r3 : i64 -> !eco.value
    eco.dbg %x3 : !eco.value
    // JIT: 3
    %b4 = arith.constant -1 : i64
    %i4 = arith.constant 32 : i64
    %r4 = func.call @index(%b4, %i4) : (i64, i64) -> i64
    %x4 = eco.box %r4 : i64 -> !eco.value
    eco.dbg %x4 : !eco.value
    // JIT: 0
    %b5 = arith.constant 5 : i64
    %i5 = arith.constant 3 : i64
    %r5 = func.call @index(%b5, %i5) : (i64, i64) -> i64
    %x5 = eco.box %r5 : i64 -> !eco.value
    eco.dbg %x5 : !eco.value
    // JIT: 2
    %p6 = arith.constant -1 : i64
    %r6 = func.call @pop(%p6) : (i64) -> i64
    %x6 = eco.box %r6 : i64 -> !eco.value
    eco.dbg %x6 : !eco.value
    // JIT: 32
    %p7 = arith.constant 8589934591 : i64
    %r7 = func.call @pop(%p7) : (i64) -> i64
    %x7 = eco.box %r7 : i64 -> !eco.value
    eco.dbg %x7 : !eco.value
    // JIT: 32
    %p8 = arith.constant 0 : i64
    %r8 = func.call @pop(%p8) : (i64) -> i64
    %x8 = eco.box %r8 : i64 -> !eco.value
    eco.dbg %x8 : !eco.value
    // JIT: 0
    %p9 = arith.constant 4294967296 : i64
    %r9 = func.call @pop(%p9) : (i64) -> i64
    %x9 = eco.box %r9 : i64 -> !eco.value
    eco.dbg %x9 : !eco.value
    // JIT: 0
    %p10 = arith.constant 255 : i64
    %r10 = func.call @pop(%p10) : (i64) -> i64
    %x10 = eco.box %r10 : i64 -> !eco.value
    eco.dbg %x10 : !eco.value
    // JIT: 8
    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
